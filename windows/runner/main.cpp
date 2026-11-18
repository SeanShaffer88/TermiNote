#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kInstanceMutexName[] = L"TermiNote-SingleInstance-7F3A";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"TermiNote";

bool IsHelpOrVersion(const std::vector<std::string>& arguments) {
  return arguments.empty() || arguments.front() == "help" ||
         arguments.front() == "version";
}

bool IsDataCliCommand(const std::vector<std::string>& arguments) {
  if (arguments.empty()) return false;
  const std::string& command = arguments.front();
  // Keep this list aligned with cliCommands in lib/cli.dart. Unknown
  // arguments still follow the GUI path rather than being treated as a
  // data command.
  return command == "add" || command == "list" || command == "listify" ||
         command == "format" || command == "render" || command == "toc" ||
         command == "export-html" || command == "show" || command == "edit" ||
         command == "search" || command == "delete" || command == "restore" ||
         command == "delete-forever" || command == "empty-trash" ||
         command == "delete-all" || command == "trash" || command == "tag" ||
         command == "untag" || command == "rename-tag" ||
         command == "tags" || command == "pin" || command == "unpin" ||
         command == "duplicate" || command == "export" ||
         command == "import" || command == "add-file" || command == "stats";
}

void RestoreExistingWindow(HWND window) {
  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(window);
}

void ReportCliLockFailure(const wchar_t* message, const char* console_message) {
  if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
    FILE* stream = nullptr;
    freopen_s(&stream, "CONOUT$", "w", stdout);
    freopen_s(&stream, "CONOUT$", "w", stderr);
  } else if (::GetLastError() != ERROR_ACCESS_DENIED) {
    ::MessageBoxW(nullptr, message, L"TermiNote", MB_OK | MB_ICONWARNING);
    return;
  }
  std::fprintf(stderr, "%s\n", console_message);
}

void ReleaseInstanceMutex(HANDLE mutex, bool owns_mutex) {
  if (mutex == nullptr) return;
  if (owns_mutex) ::ReleaseMutex(mutex);
  ::CloseHandle(mutex);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool is_cli = __argc > 1;
  const bool is_data_cli = is_cli && IsDataCliCommand(command_line_arguments);
  const bool needs_instance_lock =
      !is_cli || !IsHelpOrVersion(command_line_arguments);

  HANDLE instance_mutex = nullptr;
  bool owns_instance_mutex = false;
  if (needs_instance_lock) {
    instance_mutex = ::CreateMutexW(nullptr, TRUE, kInstanceMutexName);
    if (instance_mutex == nullptr) {
      if (is_cli) {
        ReportCliLockFailure(
            L"TermiNote could not safely access its notebook. Restart the app "
            L"and try again.",
            "TermiNote could not safely access its notebook. Restart the app "
            "and try again.");
      } else {
        ::MessageBoxW(nullptr,
                      L"TermiNote could not safely open its notebook. "
                      L"Restart the app and try again.",
                      L"TermiNote",
                      MB_OK | MB_ICONERROR);
      }
      return EXIT_FAILURE;
    }

    const bool already_exists = ::GetLastError() == ERROR_ALREADY_EXISTS;
    owns_instance_mutex = !already_exists;
    if (already_exists) {
      if (is_data_cli) {
        ReportCliLockFailure(
            L"TermiNote is open. Close it before running notebook commands.",
            "TermiNote is open. Close it before running notebook commands.");
        ReleaseInstanceMutex(instance_mutex, false);
        return EXIT_FAILURE;
      }

      const ULONGLONG deadline = ::GetTickCount64() + 10000;
      while (true) {
        HWND existing = ::FindWindowW(kWindowClassName, kWindowTitle);
        if (existing != nullptr) {
          RestoreExistingWindow(existing);
          ReleaseInstanceMutex(instance_mutex, false);
          return EXIT_SUCCESS;
        }

        const ULONGLONG now = ::GetTickCount64();
        if (now >= deadline) {
          ::MessageBoxW(nullptr,
                        L"TermiNote could not safely open its notebook. "
                        L"Close other TermiNote processes and try again.",
                        L"TermiNote",
                        MB_OK | MB_ICONERROR);
          ReleaseInstanceMutex(instance_mutex, false);
          return EXIT_FAILURE;
        }

        const DWORD wait_ms =
            static_cast<DWORD>((deadline - now) > 100 ? 100 : (deadline - now));
        const DWORD wait_result =
            ::WaitForSingleObject(instance_mutex, wait_ms);
        if (wait_result == WAIT_OBJECT_0 || wait_result == WAIT_ABANDONED) {
          owns_instance_mutex = true;
          break;
        }
        if (wait_result == WAIT_FAILED) {
          ::MessageBoxW(nullptr,
                        L"TermiNote could not safely open its notebook. "
                        L"Restart the app and try again.",
                        L"TermiNote",
                        MB_OK | MB_ICONERROR);
          ReleaseInstanceMutex(instance_mutex, false);
          return EXIT_FAILURE;
        }
      }
    }
  }

  // TermiNote: when command-line arguments are present, the Dart side runs
  // the CLI instead of the GUI, so attach to the parent process console and
  // point stdout/stderr at it. With no arguments, keep the standard
  // behaviour: attach to a console when present (e.g., 'flutter run') or
  // create a new console when running with a debugger.
  if (is_cli) {
    if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
      FILE *stream = nullptr;
      freopen_s(&stream, "CONOUT$", "w", stdout);
      freopen_s(&stream, "CONOUT$", "w", stderr);
    }
  } else if (!::AttachConsole(ATTACH_PARENT_PROCESS) &&
             ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"TermiNote", origin, size)) {
    ReleaseInstanceMutex(instance_mutex, owns_instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ReleaseInstanceMutex(instance_mutex, owns_instance_mutex);
  return EXIT_SUCCESS;
}
