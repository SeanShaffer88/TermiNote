// Tests for the 0.4.0 app-level additions: dropped-file import, the
// native filesDropped dispatch, streamed startup (window first, notes
// behind it), and the header cursor pausing while the window is
// inactive.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';
import 'package:terminote/theme.dart';
import 'package:terminote/window_channel.dart';

const MethodChannel _windowChannelForTest = MethodChannel('terminote/window');

Future<Object?> _fireNativeCall(String method, Object? arguments) {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'terminote/window',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (data) {},
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowChannelForTest, (call) async {
          return switch (call.method) {
            'hideToTray' => true,
            _ => null,
          };
        });
  });

  tearDown(() {
    WindowChannel.setTrayCommandHandler(null);
    WindowChannel.setCloseRequestHandler(null);
    WindowChannel.setFilesDroppedHandler(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_windowChannelForTest, null);
  });

  group('importDroppedFiles', () {
    test('takes usable .md/.txt files and skips the rest', () async {
      final dir = Directory.systemTemp.createTempSync('terminote_drop_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final scratch = Directory('${dir.path}/scratch')..createSync();
      File('${scratch.path}/one.md').writeAsStringSync('# Heading\nbody');
      File('${scratch.path}/two.txt').writeAsStringSync('Title line\nrest');
      File('${scratch.path}/pic.png').writeAsStringSync('not a note');
      File('${scratch.path}/empty.md').writeAsStringSync('  \n');
      final state = AppState(store: NoteStore.empty(), dataDir: dir.path);
      final result = await state.importDroppedFiles(<String>[
        '${scratch.path}/one.md',
        '${scratch.path}/two.txt',
        '${scratch.path}/pic.png',
        '${scratch.path}/empty.md',
        '${scratch.path}/missing.md',
      ]);
      expect(result.added, 2);
      expect(result.skipped, 3);
      expect(
        state.store.notes.map((n) => n.title),
        containsAll(<String>['# Heading', 'Title line']),
      );
    });
  });

  group('filesDropped dispatch', () {
    test('the native call reaches the registered handler', () async {
      List<String>? received;
      WindowChannel.setFilesDroppedHandler((paths) async {
        received = paths;
      });
      await _fireNativeCall('filesDropped', <String>[
        'C:\\a\\one.md',
        'C:\\b\\two.txt',
      ]);
      expect(received, <String>['C:\\a\\one.md', 'C:\\b\\two.txt']);
    });
  });

  group('streamed startup', () {
    testWidgets('the window shows a loading state, then the notes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('terminote_start_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      // A notebook already on disk, as a previous run left it.
      final seed = NoteStore.empty()
        ..notesDir = StoreFile.notesDirFor(dir.path);
      seed.add(title: 'Streamed note', body: 'x', now: 100);
      await seed.saveDirty();

      final state = AppState(
        store: NoteStore.empty(),
        dataDir: dir.path,
        loading: true,
      );
      await tester.pumpWidget(TermiNoteApp(state: state));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('Loading notes…'), findsOneWidget);
      expect(find.text('Streamed note'), findsNothing);

      await state.finishStart();
      await tester.pump(const Duration(milliseconds: 120));
      expect(state.loading, isFalse);
      expect(find.text('Loading notes…'), findsNothing);
      expect(find.text('Streamed note'), findsOneWidget);
    });
  });

  group('blinking cursor pause', () {
    testWidgets('the cursor stops changing while the window is inactive', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final dir = Directory.systemTemp.createTempSync('terminote_blink_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final store = NoteStore.empty();
      store.add(title: 'Blink', body: 'x', now: 100);
      final state = AppState(store: store, dataDir: dir.path);
      await tester.pumpWidget(TermiNoteApp(state: state));
      await tester.pump(const Duration(milliseconds: 120));

      Color? cursorColor() {
        for (final element
            in find
                .byWidgetPredicate(
                  (w) =>
                      w is Container &&
                      w.child == null &&
                      (w.color == kAccent || w.color == Colors.transparent),
                )
                .evaluate()) {
          if (element.size == const Size(17, 26)) {
            return (element.widget as Container).color;
          }
        }
        return null;
      }

      expect(cursorColor(), isNotNull, reason: 'header cursor not found');
      // While active, the colour changes over one blink cycle.
      final seen = <Color?>{};
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        seen.add(cursorColor());
      }
      expect(seen.length, greaterThan(1), reason: 'cursor should blink');

      // Inactive: the colour freezes, however long we wait.
      state.windowActive.value = false;
      await tester.pump(const Duration(milliseconds: 50));
      final frozen = cursorColor();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(cursorColor(), frozen);
      }
    });
  });
}
