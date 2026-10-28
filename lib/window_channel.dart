/// The small bridge to the Windows runner (the "terminote/window"
/// method channel): the system tray behaviour, and the window's
/// close-request prompt.
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

  static Future<void> Function(String command)? _trayCommandHandler;
  static Future<bool> Function()? _closeRequestHandler;

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
    _trayCommandHandler = handler;
    _syncMethodCallHandler();
  }

  /// Registers (or clears, with null) the handler the window itself
  /// asks before closing. The runner holds the close and invokes
  /// "closeRequested"; the handler answers the question "may the window
  /// close now?" — true allows the close, false keeps the window open
  /// (the user chose to keep editing after being asked about unsaved
  /// work). When no handler is registered the reply defaults to allow:
  /// the question is a courtesy, never a lock on the window.
  static void setCloseRequestHandler(Future<bool> Function()? handler) {
    _closeRequestHandler = handler;
    _syncMethodCallHandler();
  }

  /// Keeps exactly one method-call handler on the channel, dispatching
  /// every native-to-Dart call: the tray commands and the close
  /// request. The registration is removed only when neither handler
  /// remains, so clearing one never silences the other.
  static void _syncMethodCallHandler() {
    if (_trayCommandHandler == null && _closeRequestHandler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'trayCommand':
          final handler = _trayCommandHandler;
          if (handler != null) {
            await handler(call.arguments?.toString() ?? '');
          }
          return null;
        case 'closeRequested':
          final handler = _closeRequestHandler;
          if (handler == null) return 'allow';
          return await handler() ? 'allow' : 'deny';
        default:
          return null;
      }
    });
  }
}
