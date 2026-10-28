#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // TermiNote system tray support. The "terminote/window" channel
  // carries the minimize-to-tray setting from Dart (implemented in
  // lib/window_channel.dart) and tray menu commands back to Dart.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Whether minimizing tucks the window into the tray. True until Dart
  // says otherwise, matching the Dart-side default.
  bool minimize_to_tray_ = true;

  // Whether the tray icon is currently shown.
  bool tray_icon_shown_ = false;

  // The window handle the tray icon was added for, remembered so the
  // icon can still be removed on the destroy path, where the base
  // class has already cleared its own handle.
  HWND tray_hwnd_ = nullptr;

  // Adds the tray icon (app icon, "TermiNote" tooltip) if not shown.
  void AddTrayIcon();

  // Removes the tray icon if it is shown.
  void RemoveTrayIcon();

  // Brings the window back from the tray: removes the icon, shows and
  // restores the window, and brings it to the foreground.
  void RestoreFromTray();

  // Sends a tray command ("open" / "newNote") to Dart.
  void SendTrayCommand(const char* command);

  // Shows the tray icon's right-click menu at the cursor.
  void ShowTrayMenu();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
