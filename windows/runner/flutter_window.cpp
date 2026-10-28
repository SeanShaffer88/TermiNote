#include "flutter_window.h"

#include <shellapi.h>

#include <optional>
#include <string>

#include <flutter/method_result_functions.h>
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

// Timer that settles a window-close request when Dart never answers
// (the Dart side died, or the question never arrived): after this
// wait the close is allowed rather than leaving the window stuck
// open with no way to close it.
constexpr UINT_PTR kCloseAnswerTimer = 0x7B01;
constexpr UINT kCloseAnswerTimeoutMs = 5000;

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
  // say whether minimizing should tuck the window into the system tray
  // and to ask for the window to be tucked away at once ("hideToTray");
  // the tray menu sends "open" / "newNote" / "quit" back through it;
  // and before the window closes, the runner asks Dart "closeRequested"
  // through it (see AskDartAboutClose).
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
        } else if (call.method_name() == "hideToTray") {
          // Dart asks to tuck the window into the tray now (the
          // X-button choice). Same hide as the minimize path; the
          // answer says whether the window really was hidden — it is
          // only hidden when the tray icon is showing, so the window
          // can always be brought back.
          AddTrayIcon();
          bool hidden = false;
          if (tray_icon_shown_) {
            ShowWindow(GetHandle(), SW_HIDE);
            hidden = true;
          }
          result->Success(flutter::EncodableValue(hidden));
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

    case WM_CLOSE:
      // TermiNote: the window itself asks Dart before closing. Until
      // Dart allows it, the close is held (handled here, so nothing is
      // destroyed); a "deny" answer leaves the window open. A close
      // Dart has already allowed (closing_confirmed_) is not asked
      // about again — it falls through to the normal destroy path.
      if (!closing_confirmed_) {
        AskDartAboutClose(hwnd);
        return 0;
      }
      break;

    case WM_TIMER:
      // The close-question timer: if Dart still has not answered, let
      // the close proceed. A stuck question must never make the
      // window unclosable.
      if (wparam == kCloseAnswerTimer && close_request_pending_) {
        SettleCloseRequest(hwnd, true);
        return 0;
      }
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
          // Tell Dart this close is a real quit before asking: the
          // X-button choice (ask / quit / tray) must not turn the tray
          // menu's Quit into another trip to the tray. Like every
          // close, it still runs through the close prompt below, and
          // unsaved work gets its say before the program really quits.
          SendTrayCommand("quit");
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

void FlutterWindow::AskDartAboutClose(HWND hwnd) {
  if (close_request_pending_) {
    // A question is already on screen (or on its way). This extra
    // close request changes nothing.
    return;
  }
  if (window_channel_ == nullptr) {
    // No way to ask: allow the close. Asking is a courtesy for
    // unsaved work, never a lock on the window.
    AllowClose(hwnd);
    return;
  }
  close_request_pending_ = true;
  // If no answer comes back at all, this timer allows the close.
  SetTimer(hwnd, kCloseAnswerTimer, kCloseAnswerTimeoutMs, nullptr);
  window_channel_->InvokeMethod(
      "closeRequested", nullptr,
      std::make_unique<
          flutter::MethodResultFunctions<flutter::EncodableValue>>(
          // Answered. Only an exact "deny" holds the window open;
          // "allow" — and any unexpected value — lets the close
          // proceed.
          [this, hwnd](const flutter::EncodableValue* result) {
            const std::string* answer =
                result == nullptr ? nullptr
                                  : std::get_if<std::string>(result);
            const bool deny = answer != nullptr && *answer == "deny";
            SettleCloseRequest(hwnd, !deny);
          },
          // The call itself failed, or Dart has no handler for the
          // question: allow the close. The user must never be trapped
          // in a window that cannot be closed.
          [this, hwnd](const std::string& error_code,
                       const std::string& error_message,
                       const flutter::EncodableValue* error_details) {
            SettleCloseRequest(hwnd, true);
          },
          [this, hwnd]() { SettleCloseRequest(hwnd, true); }));
}

void FlutterWindow::SettleCloseRequest(HWND hwnd, bool allow) {
  if (!close_request_pending_) {
    // Already settled (the answer raced the timeout, or the window is
    // on its way out): nothing left to decide.
    return;
  }
  KillTimer(hwnd, kCloseAnswerTimer);
  close_request_pending_ = false;
  if (allow) {
    AllowClose(hwnd);
  }
}

void FlutterWindow::AllowClose(HWND hwnd) {
  closing_confirmed_ = true;
  // Posted, not sent: the close re-enters MessageHandler as a fresh
  // request, sees the confirmation above, and takes the normal path.
  PostMessage(hwnd, WM_CLOSE, 0, 0);
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
