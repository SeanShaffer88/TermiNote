// Widget tests for the 0.4.0 editor additions: F5 types a date/time
// stamp at the cursor, the count line shows words and characters, and
// the FILE button asks to show the note's file in Explorer.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/editor_screen.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';

Finder _bodyField() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'Write your note',
);

TextEditingController _bodyController(WidgetTester tester) =>
    tester.widget<TextField>(_bodyField()).controller!;

void main() {
  void useFullSizeSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<Directory> openEditor(
    WidgetTester tester, {
    required NoteStore store,
    Note? note,
  }) async {
    final dir = Directory.systemTemp.createTempSync('terminote_tools_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final state = AppState(store: store, dataDir: dir.path);
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(state: state, note: note),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));
    return dir;
  }

  testWidgets('F5 inserts a date/time stamp at the cursor', (tester) async {
    useFullSizeSurface(tester);
    final store = NoteStore.empty();
    final note = store.add(title: 'Stamped', body: 'AB', now: 100);
    await openEditor(tester, store: store, note: note);

    _bodyController(tester).selection = const TextSelection.collapsed(
      offset: 1,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    final text = _bodyController(tester).text;
    final stampPattern = RegExp(
      r'\d{4}-\d{2}-\d{2} \((Mon|Tue|Wed|Thu|Fri|Sat|Sun)\) '
      r'\d{2}:\d{2}:\d{2} (AM|PM)',
    );
    expect(stampPattern.hasMatch(text), isTrue, reason: 'body was: $text');
    expect(text.startsWith('A'), isTrue);
    expect(text.endsWith('B'), isTrue);
  });

  testWidgets('the count line shows words and characters', (tester) async {
    useFullSizeSurface(tester);
    final store = NoteStore.empty();
    final note = store.add(title: 'Counted', body: '', now: 100);
    await openEditor(tester, store: store, note: note);

    expect(find.text('0 words · 0 characters'), findsOneWidget);
    await tester.enterText(_bodyField(), 'one two three');
    await tester.pump();
    expect(find.text('3 words · 13 characters'), findsOneWidget);
  });

  testWidgets('FILE asks to show the saved note file in Explorer', (
    tester,
  ) async {
    useFullSizeSurface(tester);
    final shown = <String>[];
    final previous = showInExplorerImpl;
    showInExplorerImpl = (path) async {
      shown.add(path);
      return true;
    };
    addTearDown(() => showInExplorerImpl = previous);

    final dir = Directory.systemTemp.createTempSync('terminote_file_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = NoteStore.empty()..notesDir = StoreFile.notesDirFor(dir.path);
    final note = store.add(title: 'File button', body: 'body', now: 100);
    await store.saveDirty();
    final state = AppState(store: store, dataDir: dir.path);
    await tester.pumpWidget(
      MaterialApp(
        home: EditorScreen(state: state, note: note),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.text('FILE'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown, hasLength(1));
    expect(shown.single, store.filePathFor(note));
    expect(File(shown.single).existsSync(), isTrue);
  });
}
