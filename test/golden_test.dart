// Golden (picture) tests: render the two main screens to PNG files under
// preview/ so a human can compare them with the approved mockups.
//
// On the first run the files do not exist yet and matchesGoldenFile
// writes them (the run "fails" with a golden-missing note in some setups
// or passes by creating them, depending on the Flutter version — either
// way, after one run preview/list.png and preview/editor.png exist and
// later runs compare against them). Regenerate deliberately with:
//   flutter test --update-goldens test/golden_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/editor_screen.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';
import 'package:terminote/theme.dart';

int _epoch(int y, int m, int d, int h, int min, int s) =>
    DateTime(y, m, d, h, min, s).millisecondsSinceEpoch ~/ 1000;

NoteStore _sampleStore() {
  final store = NoteStore.empty();
  store.add(
    title: 'Trip ideas',
    body:
        'Fly into Tokyo on a Tuesday, tickets are cheaper mid-week. '
        'Stay near a train line.',
    tags: <String>['ideas', 'travel'],
    now: _epoch(2026, 10, 26, 20, 31, 10),
  );
  store.add(
    title: 'Release checklist for the new build',
    body: 'Gate, publish, verify.',
    tags: <String>['work'],
    now: _epoch(2026, 10, 27, 11, 2, 48),
  );
  final dentist = store.add(
    title: 'Call the dentist',
    body: 'Ask about the spring check-up.',
    now: _epoch(2026, 10, 27, 18, 40, 5),
  );
  store.setPinned(
    dentist.id,
    pinned: true,
    now: _epoch(2026, 10, 27, 18, 40, 5),
  );
  store.add(
    title: 'Shopping list',
    body: 'milk and eggs',
    tags: <String>['home', 'food'],
    now: _epoch(2026, 10, 28, 9, 15, 22),
  );
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void setSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('list screen render', (tester) async {
    setSurface(tester);
    final dir = Directory.systemTemp.createTempSync('terminote_golden_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final state = AppState(store: _sampleStore(), dataDir: dir.path);
    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 350));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../preview/list.png'),
    );
  });

  testWidgets('editor screen render', (tester) async {
    setSurface(tester);
    final dir = Directory.systemTemp.createTempSync('terminote_golden_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = _sampleStore();
    final state = AppState(store: store, dataDir: dir.path);
    final trip = store.notes.firstWhere((n) => n.title == 'Trip ideas');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTermiNoteTheme(),
        home: EditorScreen(state: state, note: trip),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await expectLater(
      find.byType(EditorScreen),
      matchesGoldenFile('../preview/editor.png'),
    );
  });
}
