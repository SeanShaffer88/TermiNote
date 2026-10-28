#include "flutter_window.h"

#include <shellapi.h>

#include <optional>
#include <string>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

// Command ids for the tray icon's popup menu.
constexpr UINT kTrayOpenCommand = 0x7A01;
constexpr UINT kTrayNewNoteCommand = 0x7A02;
constexpr UINT kTrayQuitCommand = 0x7A03;

// Private window message the shell sends when the tray icon is clicked.
constexpr UINT kTrayCallbackMessage = WM_APP + 0x54;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  // TermiNote: register the "terminote/window" channel. Dart uses it to
  // say whether minimizing should tuck the window into the system tray;
  // the tray menu sends "open" / "newNote" back through it.
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "terminote/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setMinimizeToTray") {
          const bool* enabled = std::get_if<bool>(call.arguments());
          if (enabled != nullptr) {
            minimize_to_tray_ = *enabled;
            // If the window is sitting in the tray when the setting is
            // switched off, bring it back so it cannot be stranded
            // there with no way to reach it.
            if (!minimize_to_tray_ && tray_icon_shown_) {
              RestoreFromTray();
            }
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  window_channel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_SIZE:
      // TermiNote: with the tray setting on, minimizing tucks the
      // window into the system tray instead of leaving it on the
      // taskbar. With the setting off, nothing happens here and the
      // minimize is a normal one.
      if (wparam == SIZE_MINIMIZED && minimize_to_tray_) {
        AddTrayIcon();
        if (tray_icon_shown_) {
          ShowWindow(hwnd, SW_HIDE);
        }
      }
      break;

    case kTrayCallbackMessage: {
      // Mouse events on the tray icon.
      const UINT event = static_cast<UINT>(lparam);
      if (event == WM_LBUTTONDBLCLK) {
        RestoreFromTray();
        SendTrayCommand("open");
      } else if (event == WM_RBUTTONUP) {
        ShowTrayMenu();
      }
      return 0;
    }

    case WM_COMMAND:
      // Commands from the tray icon's popup menu.
      switch (LOWORD(wparam)) {
        case kTrayOpenCommand:
          RestoreFromTray();
          SendTrayCommand("open");
          return 0;
        case kTrayNewNoteCommand:
          RestoreFromTray();
          SendTrayCommand("newNote");
          return 0;
        case kTrayQuitCommand:
          RemoveTrayIcon();
          // A normal close, posted rather than forced, so the Dart
          // side still gets its say about unsaved work before the
          // program really quits.
          PostMessage(hwnd, WM_CLOSE, 0, 0);
          return 0;
      }
      break;

    case WM_DESTROY:
      RemoveTrayIcon();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || tray_icon_shown_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = hwnd;
  data.uID = 1;
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  // The app icon from the runner resources. LoadIcon hands back a
  // shared icon, so it must not be destroyed afterwards.
  data.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"TermiNote");
  if (Shell_NotifyIconW(NIM_ADD, &data)) {
    tray_icon_shown_ = true;
    tray_hwnd_ = hwnd;
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_shown_) {
    return;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  // The remembered handle, not GetHandle(): on the destroy path the
  // base class clears its handle before this runs.
  data.hWnd = tray_hwnd_;
  data.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &data);
  tray_icon_shown_ = false;
  tray_hwnd_ = nullptr;
}

void FlutterWindow::RestoreFromTray() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  RemoveTrayIcon();
  ShowWindow(hwnd, SW_SHOW);
  ShowWindow(hwnd, SW_RESTORE);
  SetForegroundWindow(hwnd);
}

void FlutterWindow::SendTrayCommand(const char* command) {
  if (window_channel_ == nullptr) {
    return;
  }
  window_channel_->InvokeMethod(
      "trayCommand",
      std::make_unique<flutter::EncodableValue>(std::string(command)));
}

void FlutterWindow::ShowTrayMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kTrayOpenCommand, L"Open TermiNote");
  AppendMenuW(menu, MF_STRING, kTrayNewNoteCommand, L"New note");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayQuitCommand, L"Quit");
  // A tray menu only shows, dismisses, and reports its clicks properly
  // when the owner window is in the foreground first.
  SetForegroundWindow(hwnd);
  POINT cursor{};
  GetCursorPos(&cursor);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, hwnd,
                 nullptr);
  DestroyMenu(menu);
}
