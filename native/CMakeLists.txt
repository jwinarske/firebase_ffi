# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.22)
# Abstract the MSVC runtime selection into a target property, so it can follow
# what the SDK published rather than the compiler's default.
if(POLICY CMP0091)
  cmake_policy(SET CMP0091 NEW)
endif()

project(firebase_ffi CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# dart_api_dl is C, and the VM fills its function table at runtime; it must not
# be compiled as C++.
# CBOR, vendored. The wire format between C++ and Dart is RFC 8949 rather than
# a private encoding: the Dart side decodes with a conformant package, so a
# malformed message is caught by an implementation this project did not write.
add_library(tinycbor OBJECT
    third_party/tinycbor/src/cborencoder.c
    third_party/tinycbor/src/cborencoder_float.c
    third_party/tinycbor/src/cborparser.c
    third_party/tinycbor/src/cborparser_dup_string.c
    third_party/tinycbor/src/cborparser_float.c)
target_include_directories(tinycbor PUBLIC third_party/tinycbor/src)
# Selects the checked-in cbor_cfg.h in place of the one upstream's CMake
# generates; see third_party/tinycbor/README.md.
target_compile_definitions(tinycbor PUBLIC CBOR_EXTERNAL_CFG)
# Third-party source: not this project's warnings to fix.
target_compile_options(tinycbor PRIVATE $<$<NOT:$<C_COMPILER_ID:MSVC>>:-w>)

add_library(dart_api_dl OBJECT src/dart_api_dl.c)
target_include_directories(dart_api_dl PUBLIC include)

add_library(firebase_ffi SHARED src/transport.cpp
            $<TARGET_OBJECTS:dart_api_dl> $<TARGET_OBJECTS:tinycbor>)
target_include_directories(firebase_ffi PUBLIC include PRIVATE third_party/tinycbor/src)
target_compile_definitions(firebase_ffi PRIVATE CBOR_EXTERNAL_CFG)
set_target_properties(firebase_ffi PROPERTIES
  OUTPUT_NAME firebase_ffi
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden)

find_package(Threads REQUIRED)
target_link_libraries(firebase_ffi PRIVATE Threads::Threads)

# A shared library links by default even when symbols are left unresolved, and
# the loader is then the first thing to complain -- on the target, at dlopen.
# An SDK built with the wrong libstdc++ ABI produced exactly that: a library
# CI called successfully built, with every std::string-taking Firestore and
# Auth entry point missing. Resolve at link time so the build is the thing
# that fails.
include(CheckLinkerFlag OPTIONAL RESULT_VARIABLE _have_check_linker_flag)
if(_have_check_linker_flag)
  check_linker_flag(CXX "LINKER:--no-undefined" FDB_LD_NO_UNDEFINED)
  if(FDB_LD_NO_UNDEFINED)
    target_link_options(firebase_ffi PRIVATE "LINKER:--no-undefined")
  endif()
endif()

# ── Firebase C++ SDK ────────────────────────────────────────────────────────
#
# Resolved from the prefix the SDK was installed into. Under emb this is the
# cross sysroot an `augment:` staged it to, reached because emb's cmake wrapper
# injects the cross toolchain file, which carries CMAKE_SYSROOT and
# CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY. On a host build point CMAKE_PREFIX_PATH
# at the install prefix instead. Optional so the transport benchmark still
# builds standalone with no SDK present.
option(FDB_WITH_FIREBASE "Link the Firebase C++ SDK and use the real Database" ON)

if(FDB_WITH_FIREBASE)
  find_package(firebase_cpp_sdk CONFIG QUIET)
  if(NOT firebase_cpp_sdk_FOUND)
    # Fail rather than quietly emit a stub. Falling back to the transport-only
    # library builds and links fine, then fails at runtime as "build has no
    # Firebase SDK" with nothing pointing back at this configure step. Opting
    # out has to be deliberate.
    message(FATAL_ERROR
      "firebase_ffi: the Firebase C++ SDK was not found.\n"
      "Point at an install prefix containing lib/cmake/firebase_cpp_sdk by "
      "adding to the consuming package's pubspec.yaml:\n"
      "  hooks:\n"
      "    user_defines:\n"
      "      firebase_ffi:\n"
      "        firebase_sdk: path/to/prefix   # relative to that pubspec\n"
      "Or build the transport benchmark alone with with_firebase: false.")
  endif()
endif()

if(firebase_cpp_sdk_FOUND)
  message(STATUS "firebase_ffi: Firebase C++ SDK ${firebase_cpp_sdk_VERSION}")
  target_compile_definitions(firebase_ffi PRIVATE FDB_HAVE_FIREBASE=1)
  target_sources(firebase_ffi PRIVATE src/firebase_impl.cpp src/auth_impl.cpp)

  # Firestore is opt-in, and off by default. Its archives bring gRPC, protobuf
  # and abseil, which an app binding only Auth and Database should not carry:
  # the linker takes only what something references, so not compiling this file
  # is what keeps them out of the library.
  option(FDB_WITH_STORAGE "Bind Cloud Storage" OFF)
  if(FDB_WITH_STORAGE)
    target_sources(firebase_ffi PRIVATE src/storage_impl.cpp)
    target_compile_definitions(firebase_ffi PRIVATE FDB_HAVE_STORAGE=1)
  endif()

  option(FDB_WITH_FIRESTORE "Bind Cloud Firestore" OFF)
  if(FDB_WITH_FIRESTORE)
    target_sources(firebase_ffi PRIVATE src/firestore_impl.cpp)
    target_compile_definitions(firebase_ffi PRIVATE FDB_HAVE_FIRESTORE=1)
    message(STATUS "firebase_ffi: binding Firestore")
  endif()
  target_include_directories(firebase_ffi PRIVATE ${firebase_cpp_sdk_INCLUDE_DIRS})
  # How the SDK links is the only platform-specific part; the C ABI and the
  # Dart side are neutral. The system libraries the SDK itself needs come from
  # the package config (firebase_cpp_sdk_SYSTEM_LIBS), so they are decided by
  # whoever built the SDK rather than guessed at here.
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    # libsecret and libuuid are link-time requirements of the SDK on Linux, not
    # just runtime ones. Found through pkg-config when the SDK's config does not
    # publish them (an SDK built before that was added).
    if(NOT firebase_cpp_sdk_SYSTEM_LIBS)
      find_package(PkgConfig REQUIRED)
      pkg_check_modules(UUID REQUIRED IMPORTED_TARGET uuid)
      pkg_check_modules(SECRET REQUIRED IMPORTED_TARGET libsecret-1)
      set(firebase_cpp_sdk_SYSTEM_LIBS PkgConfig::UUID PkgConfig::SECRET)
    endif()
    # Grouped: the SDK's archives have cycles between firebase_app and
    # firebase_rest_lib that no single ordering resolves. --start-group is
    # GNU ld only.
    target_link_libraries(firebase_ffi PRIVATE
        -Wl,--start-group ${firebase_cpp_sdk_LIBRARIES} -Wl,--end-group
        ${firebase_cpp_sdk_SYSTEM_LIBS})
  elseif(APPLE)
    # ld64 accepts no --start-group and resolves the archive cycles unaided.
    # The frameworks come from the SDK's own config: Keychain lives in
    # Security, which pulls in CoreFoundation.
    target_link_libraries(firebase_ffi PRIVATE
        ${firebase_cpp_sdk_LIBRARIES} ${firebase_cpp_sdk_SYSTEM_LIBS})
  elseif(WIN32)
    # The SDK is built with MSVC, so a consumer has to be as well: MinGW cannot
    # link MSVC C++ archives, and the Dart toolchain resolves to MinGW GCC on
    # Windows unless told otherwise. Refusing here names the mismatch; the
    # alternative is a wall of unresolved externals that names nothing.
    if(NOT MSVC)
      message(FATAL_ERROR
        "firebase_ffi: the Firebase C++ SDK is built with MSVC, but this build "
        "is using ${CMAKE_CXX_COMPILER_ID}. A MinGW consumer cannot link MSVC "
        "archives.\n"
        "Select MSVC through hooks.user_defines.firebase_ffi.cc/cxx (cl), with "
        "the MSVC environment on PATH.")
    endif()
    # Match the C runtime the SDK was compiled against. Mixing /MT and /MD
    # fails at link with LNK2038 naming every object file; the SDK's config
    # records which one it used so both halves cannot drift apart.
    # Every target, not just the shared library: dart_api_dl is a separate
    # object library, and a single object compiled against the other runtime is
    # enough to produce LNK4098 and an import of the wrong CRT.
    if(firebase_cpp_sdk_MSVC_RUNTIME_LIBRARY)
      foreach(_t firebase_ffi dart_api_dl tinycbor)
        set_property(TARGET ${_t} PROPERTY
                     MSVC_RUNTIME_LIBRARY "${firebase_cpp_sdk_MSVC_RUNTIME_LIBRARY}")
      endforeach()
    endif()
    # MSVC's linker makes repeated passes over the libraries it is given, so
    # the archive cycles need no group directive. The Windows libraries the SDK
    # needs — wincred for credential storage, and its networking stack's
    # dependencies — come from the package config like every other platform's.
    target_link_libraries(firebase_ffi PRIVATE
        ${firebase_cpp_sdk_LIBRARIES} ${firebase_cpp_sdk_SYSTEM_LIBS})
  else()
    # Stop here rather than guess. A wrong link line fails deep inside the
    # linker with nothing naming this file, and an untested platform claimed as
    # supported is worse than one honestly refused.
    message(FATAL_ERROR
      "firebase_ffi: linking the Firebase C++ SDK is implemented for Linux, "
      "macOS and Windows; ${CMAKE_SYSTEM_NAME} is untested.\n"
      "Build without the SDK using with_firebase: false.")
  endif()
else()
  message(STATUS "firebase_ffi: no Firebase SDK — transport benchmark only")
endif()

# --- tests ------------------------------------------------------------------
#
# Off by default so a consuming app's build hook never pays for them; CI turns
# them on. They need the SDK, because the codec speaks firebase::Variant and
# firebase::firestore::FieldValue.
option(FDB_BUILD_TESTS "Build the native codec tests" OFF)
if(FDB_BUILD_TESTS AND firebase_cpp_sdk_FOUND)
  enable_testing()
  add_executable(fdb_codec_test test/codec_test.cpp)
  target_include_directories(fdb_codec_test PRIVATE
      include third_party/tinycbor/src ${firebase_cpp_sdk_INCLUDE_DIRS})
  target_compile_definitions(fdb_codec_test PRIVATE
      CBOR_EXTERNAL_CFG FDB_HAVE_FIREBASE=1
      $<$<BOOL:${FDB_WITH_FIRESTORE}>:FDB_HAVE_FIRESTORE=1>
      $<$<BOOL:${FDB_WITH_STORAGE}>:FDB_HAVE_STORAGE=1>)
  # Links the library, not its sources. Compiling firestore_impl.cpp a second
  # time and re-deriving the SDK link line meant maintaining two link recipes,
  # and the second one resolved Firestore's symbols differently from the first.
  # This way the test exercises the binary an application actually loads.
  target_link_libraries(fdb_codec_test PRIVATE firebase_ffi)
  add_test(NAME codec COMMAND fdb_codec_test)
endif()

if(NOT MSVC)
  target_compile_options(firebase_ffi PRIVATE -O2 -Wall -Wextra)
endif()
