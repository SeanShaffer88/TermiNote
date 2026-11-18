// Tests for the 0.4.0 app-level additions: dropped-file import, the
// native filesDropped dispatch, streamed startup (window first, notes
// behind it), and the header cursor pausing while the window is
// inactive.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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
      // A notebook already on disk, as a previous run left it. The
      // save and the load below do real file work, which a widget
      // test's fake clock would deadlock — runAsync lets them run.
      final seed = NoteStore.empty()
        ..notesDir = StoreFile.notesDirFor(dir.path);
      seed.add(title: 'Streamed note', body: 'x', now: 100);
      await tester.runAsync(() => seed.saveDirty());

      final state = AppState(
        store: NoteStore.empty(),
        dataDir: dir.path,
        loading: true,
      );
      await tester.pumpWidget(TermiNoteApp(state: state));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.text('Loading notes…'), findsOneWidget);
      expect(find.text('Streamed note'), findsNothing);

      await tester.runAsync(() => state.finishStart());
      await tester.pump(const Duration(milliseconds: 120));
      expect(state.loading, isFalse);
      expect(find.text('Loading notes…'), findsNothing);
      expect(find.text('Streamed note'), findsOneWidget);
    });
  });

  group('window activation', () {
    testWidgets('tracks inactive and resumed lifecycle states', (tester) async {
      final dir = Directory.systemTemp.createTempSync('terminote_blink_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final state = AppState(store: NoteStore.empty(), dataDir: dir.path);
      await tester.pumpWidget(TermiNoteApp(state: state));
      await tester.pump(const Duration(milliseconds: 120));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(state.windowActive.value, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(state.windowActive.value, isTrue);
    });
  });
}
