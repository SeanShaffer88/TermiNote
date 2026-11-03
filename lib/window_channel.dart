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

/// Where the window sits on the screen: its normal (un-maximized)
/// position and size in screen pixels, plus whether it is maximized.
/// Persisted in the settings file so the window reopens exactly where
/// it was left. The native side reports and applies these through
/// the Win32 window-placement APIs, which keep the normal rectangle
/// correct even while the window is maximized.
class WindowPlacement {
  const WindowPlacement({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.maximized,
  });

  final int left;
  final int top;
  final int width;
  final int height;
  final bool maximized;

  /// A placement worth applying: a real window size, not a sliver or
  /// an absurd rectangle from a damaged settings file. Whether it is
  /// on a connected screen is the native side's call (it refuses a
  /// rectangle no monitor overlaps).
  bool get isSane =>
      width >= 200 && height >= 150 && width <= 20000 && height <= 20000;

  Map<String, Object?> toMap() => <String, Object?>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'maximized': maximized,
  };

  /// Reads a placement back from a settings map; null when the map is
  /// missing, incomplete, or not sane — a broken saved position must
  /// never stop the window opening in its default place.
  static WindowPlacement? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final left = raw['left'];
    final top = raw['top'];
    final width = raw['width'];
    final height = raw['height'];
    if (left is! num || top is! num || width is! num || height is! num) {
      return null;
    }
    final placement = WindowPlacement(
      left: left.toInt(),
      top: top.toInt(),
      width: width.toInt(),
      height: height.toInt(),
      maximized: raw['maximized'] == true,
    );
    return placement.isSane ? placement : null;
  }
}

/// Dart ↔ native calls for window/tray behaviour.
class WindowChannel {
  WindowChannel._();

  static const MethodChannel _channel = MethodChannel('terminote/window');

  static Future<void> Function(String command)? _trayCommandHandler;
  static Future<bool> Function()? _closeRequestHandler;
  static Future<void> Function(List<String> paths)? _filesDroppedHandler;

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

  /// Asks the runner to tuck the window into the system tray now (the
  /// X-button choice "Minimize to the system tray"). Returns true when
  /// the window was hidden; false when there is no tray to tuck into
  /// (no native side, or the tray icon could not be shown) — the
  /// caller must not treat the window as hidden then.
  static Future<bool> hideToTray() async {
    try {
      return await _channel.invokeMethod<bool>('hideToTray') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Asks the runner where the window is now (see [WindowPlacement]).
  /// Null when there is no native side or the answer is unusable.
  static Future<WindowPlacement?> getWindowPlacement() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('getWindowPlacement');
      return WindowPlacement.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Asks the runner to put the window back where [placement] says.
  /// The runner refuses a rectangle no connected monitor overlaps, so
  /// a position saved on a since-unplugged screen can never strand
  /// the window off-screen. Returns true when it was applied.
  static Future<bool> setWindowPlacement(WindowPlacement placement) async {
    try {
      return await _channel.invokeMethod<bool>(
            'setWindowPlacement',
            placement.toMap(),
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
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

  /// Registers (or clears, with null) the handler for files dropped
  /// onto the window: the runner sends their full paths, and the app
  /// turns the usable ones into notes.
  static void setFilesDroppedHandler(
    Future<void> Function(List<String> paths)? handler,
  ) {
    _filesDroppedHandler = handler;
    _syncMethodCallHandler();
  }

  /// Keeps exactly one method-call handler on the channel, dispatching
  /// every native-to-Dart call: the tray commands, the close request,
  /// and dropped files. The registration is removed only when no
  /// handler remains, so clearing one never silences the others.
  static void _syncMethodCallHandler() {
    if (_trayCommandHandler == null &&
        _closeRequestHandler == null &&
        _filesDroppedHandler == null) {
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
        case 'filesDropped':
          final handler = _filesDroppedHandler;
          if (handler != null) {
            final raw = call.arguments;
            final paths = raw is List
                ? raw.map((e) => e.toString()).toList()
                : <String>[];
            await handler(paths);
          }
          return null;
        default:
          return null;
      }
    });
  }
}
