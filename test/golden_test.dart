// Render the editor to its approved PNG under preview/. The list uses
// behavior assertions because its layout is intentionally compact and
// redesigned independently of the older full-window screenshot.
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

  testWidgets('list screen shows compact terminal layout', (tester) async {
    setSurface(tester);
    final dir = Directory.systemTemp.createTempSync('terminote_golden_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final state = AppState(store: _sampleStore(), dataDir: dir.path);
    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Note Tags'), findsOneWidget);
    expect(find.text('Add note'), findsOneWidget);
    expect(find.text('Search notes'), findsOneWidget);
    expect(find.text('Delete all'), findsOneWidget);
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('Trip ideas'), findsOneWidget);
    expect(find.textContaining('Fly into Tokyo'), findsNothing);
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
