# SPDX-FileCopyrightText: 2026 Joel Winarske
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.22)
project(firebase_ffi CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# dart_api_dl is C, and the VM fills its function table at runtime; it must not
# be compiled as C++.
add_library(dart_api_dl OBJECT src/dart_api_dl.c)
target_include_directories(dart_api_dl PUBLIC include)

add_library(firebase_ffi SHARED src/transport.cpp $<TARGET_OBJECTS:dart_api_dl>)
target_include_directories(firebase_ffi PUBLIC include)
set_target_properties(firebase_ffi PROPERTIES
  OUTPUT_NAME firebase_ffi
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden)

find_package(Threads REQUIRED)
target_link_libraries(firebase_ffi PRIVATE Threads::Threads)

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
  else()
    # Stop here rather than guess. A wrong link line fails deep inside the
    # linker with nothing naming this file, and an untested platform claimed as
    # supported is worse than one honestly refused.
    #
    # Windows needs: the credential API in place of libsecret/libuuid, a
    # replacement for --start-group (MSVC needs the archives repeated or
    # combined), and install rules in the SDK augment, which currently refuse
    # MSVC outright.
    message(FATAL_ERROR
      "firebase_ffi: linking the Firebase C++ SDK is implemented for Linux and "
      "macOS; ${CMAKE_SYSTEM_NAME} is untested.\n"
      "Build without the SDK using with_firebase: false.")
  endif()
else()
  message(STATUS "firebase_ffi: no Firebase SDK — transport benchmark only")
endif()

if(NOT MSVC)
  target_compile_options(firebase_ffi PRIVATE -O2 -Wall -Wextra)
endif()
