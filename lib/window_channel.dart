/// The small bridge to the Windows runner (the "terminote/window"
/// method channel), used for the system tray behaviour.
///
/// The native side is implemented in `windows/runner/flutter_window.cpp`.
/// Everything here is defensive: in widget tests (and on any platform
/// without the native side) the channel simply does nothing, so GUI code
/// can call it without checking where it is running.
library;

import 'package:flutter/services.dart';

/// Dart ↔ native calls for window/tray behaviour.
class WindowChannel {
  WindowChannel._();

  static const MethodChannel _channel = MethodChannel('terminote/window');

  /// Tells the runner whether minimizing the window should tuck the
  /// program into the system tray (true) or minimize normally (false).
  /// Called at startup with the saved setting, and again whenever the
  /// setting changes.
  static Future<void> setMinimizeToTray(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setMinimizeToTray', enabled);
    } on MissingPluginException {
      // No native side (tests, other platforms): nothing to tell.
    } on PlatformException {
      // The runner refused the call; the setting simply has no effect
      // this run rather than crashing the app over a tray preference.
    }
  }

  /// Registers (or clears, with null) the handler for commands sent from
  /// the tray icon: "open" (the window has been restored) and "newNote"
  /// (restore + start a fresh note). The native side restores the window
  /// itself before sending, so "open" needs no window work in Dart.
  static void setTrayCommandHandler(
    Future<void> Function(String command)? handler,
  ) {
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'trayCommand') return;
      final command = call.arguments?.toString() ?? '';
      await handler(command);
    });
  }
}
