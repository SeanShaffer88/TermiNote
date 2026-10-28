#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdio>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // TermiNote: the command line decides which program this process is.
  // With arguments, the Dart side runs the CLI and never opens a window;
  // with no arguments, it opens the window.
  const bool is_cli = __argc > 1;

  // TermiNote single-instance guard (window launches only). Two running
  // windows would share one notes folder, and two editors open on the
  // same note would silently overwrite each other, so a second window
  // launch does not start at all: it brings the already-running window
  // forward and exits. Command-line calls are exempt — they are short,
  // only touch the note files one at a time, and running one while the
  // window is open is normal and safe. If the guard itself cannot be
  // set up, the program starts anyway: the guard must never be the
  // reason TermiNote does not open.
  HANDLE instance_mutex = nullptr;
  if (!is_cli) {
    instance_mutex =
        ::CreateMutexW(nullptr, FALSE, L"TermiNote-SingleInstance-7F3A");
    if (instance_mutex != nullptr &&
        ::GetLastError() == ERROR_ALREADY_EXISTS) {
      // Another copy holds the name. Find its window (same window class
      // the runner registers in win32_window.cpp, same title) and bring
      // it to the front, then leave quietly: this process never opens a
      // window and never touches the notes.
      HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW",
                                    L"TermiNote");
      if (existing != nullptr) {
        if (::IsIconic(existing)) {
          ::ShowWindow(existing, SW_RESTORE);
        } else {
          ::ShowWindow(existing, SW_SHOW);
        }
        ::SetForegroundWindow(existing);
      }
      ::CloseHandle(instance_mutex);
      return EXIT_SUCCESS;
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"TermiNote", origin, size)) {
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  // Let go of the single-instance name. (The operating system would
  // release it when the process ends anyway; this just keeps the
  // lifetime explicit.)
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
