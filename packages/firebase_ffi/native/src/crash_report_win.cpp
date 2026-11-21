// SPDX-FileCopyrightText: 2026 Joel Winarske
// SPDX-License-Identifier: Apache-2.0

// Windows, debug_info builds only: say why the process is aborting.
//
// An abort in this library -- std::terminate, an abort() in the SDK, an
// invalid argument to a CRT function -- ends the process with 0xC0000409 and
// nothing in the log. The Dart VM's crash dump does not run: it reports
// exceptions, and a fail-fast is not one. So the C runtime's two hooks on that
// path are taken here, and each prints the reason and the stack as
// module+offset before letting the abort go on. The offsets resolve against
// the PDB a debug_info build writes beside the DLL.
//
// Both hooks belong to the C runtime the library links. With the static
// runtime that is the library's own copy, and the host's are untouched. With
// the DLL runtime they are process-wide, which is why this is built only when
// debug_info asks for it.

#define WIN32_LEAN_AND_MEAN
#include <intrin.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include <exception>

namespace {

constexpr USHORT kMaxFrames = 62;

void PrintStack() {
  void* frames[kMaxFrames];
  // Skip this function and the hook that called it.
  const USHORT n = CaptureStackBackTrace(2, kMaxFrames, frames, nullptr);
  for (USHORT i = 0; i < n; ++i) {
    HMODULE module = nullptr;
    char name[MAX_PATH] = "?";
    if (!GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            static_cast<LPCSTR>(frames[i]), &module)) {
      module = nullptr;
    } else if (GetModuleFileNameA(module, name, MAX_PATH) == 0) {
      strcpy_s(name, "?");
    }
    const char* base = strrchr(name, '\\');
    // Outside any module, the address itself.
    const auto at = reinterpret_cast<uintptr_t>(frames[i]);
    const auto offset = at - reinterpret_cast<uintptr_t>(module);
    fprintf(stderr, "  #%02u %s+0x%llx\n", static_cast<unsigned>(i),
            base != nullptr ? base + 1 : name,
            static_cast<unsigned long long>(module != nullptr ? offset : at));
  }
}

// What std::terminate was handling, when it was handling something.
void PrintCurrentException() {
  const std::exception_ptr current = std::current_exception();
  if (!current) return;
  try {
    std::rethrow_exception(current);
  } catch (const std::exception& e) {
    fprintf(stderr, "fdb: uncaught exception: %s\n", e.what());
  } catch (...) {
    fprintf(stderr, "fdb: uncaught exception of a non-std type\n");
  }
}

void OnAbort(int /*signal*/) {
  fprintf(stderr, "fdb: abort on thread %lu\n", GetCurrentThreadId());
  PrintCurrentException();
  PrintStack();
  fflush(stderr);
  // Back to the default and return: abort() goes on to fail fast, which is
  // what Windows Error Reporting keeps a dump of.
  signal(SIGABRT, SIG_DFL);
}

void OnInvalidParameter(const wchar_t* expression, const wchar_t* function,
                        const wchar_t* file, unsigned int line,
                        uintptr_t /*reserved*/) {
  // The release runtime passes nulls for all four; a debug one fills them in.
  fprintf(stderr, "fdb: invalid parameter on thread %lu: %ls in %ls (%ls:%u)\n",
          GetCurrentThreadId(), expression != nullptr ? expression : L"?",
          function != nullptr ? function : L"?", file != nullptr ? file : L"?",
          line);
  PrintStack();
  fflush(stderr);
  // Returning would hand the caller EINVAL and carry on. The default ends the
  // process here, and so does this.
  __fastfail(FAST_FAIL_INVALID_ARG);
}

// At load, before anything in the library can abort.
const bool g_installed = [] {
  signal(SIGABRT, OnAbort);
  _set_invalid_parameter_handler(OnInvalidParameter);
  return true;
}();

}  // namespace
