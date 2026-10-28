// Tests for the window-close prompt glue (improvement #4).
//
// The Windows runner holds a close and asks Dart "closeRequested" over
// the terminote/window channel; Dart answers "allow" or "deny". The
// native side cannot run here, so these tests cover the Dart half:
// the channel dispatch (including that it is one merged registration
// beside the tray commands) and the app-level decision behind it —
// clean closes are allowed silently, a dirty editor shows the real
// "Save before quitting?" dialog, and each dialog choice maps to the
// right answer. Native behaviour on a real machine stays Unverified.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';
import 'package:terminote/window_channel.dart';

const StandardMethodCodec _codec = StandardMethodCodec();
const String _channelName = 'terminote/window';

/// Sends a call into Dart exactly the way the runner does (a platform
/// message on the channel) and returns the decoded reply.
Future<Object?> _platformCall(String method, [Object? arguments]) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Object? reply;
  var answered = false;
  await messenger.handlePlatformMessage(
    _channelName,
    _codec.encodeMethodCall(MethodCall(method, arguments)),
    (ByteData? data) {
      answered = true;
      if (data != null) reply = _codec.decodeEnvelope(data);
    },
  );
  expect(answered, isTrue, reason: 'the Dart handler should reply');
  return reply;
}

/// Records the reply to a close request fired without awaiting it, so
/// a widget test can interact with the dialog before the answer lands.
class _CloseProbe {
  bool answered = false;
  Object? reply;
}

_CloseProbe _fireCloseRequest() {
  final probe = _CloseProbe();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  unawaited(
    messenger.handlePlatformMessage(
      _channelName,
      _codec.encodeMethodCall(const MethodCall('closeRequested')),
      (ByteData? data) {
        probe.answered = true;
        if (data != null) probe.reply = _codec.decodeEnvelope(data);
      },
    ),
  );
  return probe;
}

/// Alternates real waits and fake pumps until [done] holds. The close
/// decision writes the settings file (real file IO) before answering,
/// and real IO only completes outside the test's fake-async zone — the
/// same pattern the editor save test in widget_test.dart uses.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 50 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Directory _tempDir() {
  final dir = Directory.systemTemp.createTempSync('terminote_close_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('window channel dispatch', () {
    tearDown(() {
      WindowChannel.setTrayCommandHandler(null);
      WindowChannel.setCloseRequestHandler(null);
    });

    test('an allowing close handler answers "allow"', () async {
      WindowChannel.setCloseRequestHandler(() async => true);
      expect(await _platformCall('closeRequested'), 'allow');
    });

    test('a denying close handler answers "deny"', () async {
      WindowChannel.setCloseRequestHandler(() async => false);
      expect(await _platformCall('closeRequested'), 'deny');
    });

    test('no close handler still answers "allow"', () async {
      // A tray handler keeps the channel registration alive, the way
      // the app always has one registered. (With no registration at
      // all the runner sees a failed call instead, which it likewise
      // treats as allow — that half is native and not testable here.)
      WindowChannel.setTrayCommandHandler((_) async {});
      expect(await _platformCall('closeRequested'), 'allow');
    });

    test('tray commands still arrive beside the close handler', () async {
      final commands = <String>[];
      WindowChannel.setTrayCommandHandler((command) async {
        commands.add(command);
      });
      WindowChannel.setCloseRequestHandler(() async => false);
      await _platformCall('trayCommand', 'newNote');
      expect(commands, <String>['newNote']);
      expect(await _platformCall('closeRequested'), 'deny');
      // Clearing one handler must not silence the other.
      WindowChannel.setCloseRequestHandler(null);
      expect(await _platformCall('closeRequested'), 'allow');
      await _platformCall('trayCommand', 'open');
      expect(commands, <String>['newNote', 'open']);
    });
  });

  group('app close decision', () {
    Future<AppState> pumpApp(WidgetTester tester) async {
      final state = AppState(
        store: NoteStore.empty(),
        dataDir: _tempDir().path,
      );
      await tester.pumpWidget(TermiNoteApp(state: state));
      await tester.pump(const Duration(milliseconds: 120));
      return state;
    }

    testWidgets('a clean app is allowed to close without asking', (
      tester,
    ) async {
      await pumpApp(tester);
      final probe = _fireCloseRequest();
      await _pumpUntil(tester, () => probe.answered);
      expect(probe.answered, isTrue);
      expect(probe.reply, 'allow');
      expect(find.text('Save before quitting?'), findsNothing);
    });

    testWidgets('a dirty editor: "Keep working" denies the close', (
      tester,
    ) async {
      final state = await pumpApp(tester);
      var flushed = false;
      var discarded = false;
      state.registerEditor(
        flush: () async {
          flushed = true;
          return true;
        },
        discard: () => discarded = true,
      );
      state.editorDirty = true;

      final probe = _fireCloseRequest();
      await _pumpUntil(
        tester,
        () => find.text('Save before quitting?').evaluate().isNotEmpty,
      );
      expect(find.text('Save before quitting?'), findsOneWidget);

      await tester.tap(find.text('Keep working'));
      await _pumpUntil(tester, () => probe.answered);
      expect(probe.reply, 'deny');
      expect(flushed, isFalse);
      expect(discarded, isFalse);
      // The program is still open on the list screen. (Drain the
      // dialog's exit animation before asserting it is gone.)
      await _pumpUntil(
        tester,
        () => find.text('Save before quitting?').evaluate().isEmpty,
      );
      expect(find.text('Save before quitting?'), findsNothing);
      expect(find.text('Add note'), findsOneWidget);
    });

    testWidgets('a dirty editor: "Save and quit" flushes and allows', (
      tester,
    ) async {
      final state = await pumpApp(tester);
      var flushed = false;
      var discarded = false;
      state.registerEditor(
        flush: () async {
          flushed = true;
          return true;
        },
        discard: () => discarded = true,
      );
      state.editorDirty = true;

      final probe = _fireCloseRequest();
      await _pumpUntil(
        tester,
        () => find.text('Save before quitting?').evaluate().isNotEmpty,
      );
      expect(find.text('Save before quitting?'), findsOneWidget);

      await tester.tap(find.text('Save and quit'));
      await _pumpUntil(tester, () => probe.answered);
      expect(probe.reply, 'allow');
      expect(flushed, isTrue);
      expect(discarded, isFalse);
    });

    testWidgets('a dirty editor: "Quit without saving" discards and allows', (
      tester,
    ) async {
      final state = await pumpApp(tester);
      var flushed = false;
      var discarded = false;
      state.registerEditor(
        flush: () async {
          flushed = true;
          return true;
        },
        discard: () => discarded = true,
      );
      state.editorDirty = true;

      final probe = _fireCloseRequest();
      await _pumpUntil(
        tester,
        () => find.text('Save before quitting?').evaluate().isNotEmpty,
      );
      expect(find.text('Save before quitting?'), findsOneWidget);

      await tester.tap(find.text('Quit without saving'));
      await _pumpUntil(tester, () => probe.answered);
      expect(probe.reply, 'allow');
      expect(flushed, isFalse);
      expect(discarded, isTrue);
    });
  });
}
