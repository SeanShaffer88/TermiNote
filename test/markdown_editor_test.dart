// Widget tests for the Markdown editor slice: the formatting toolbar
// wraps the selection, and the Preview switch renders the note and
// switches back.
import 'dart:io';

import 'package:flutter/material.dart';
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
  Future<void> openEditor(
    WidgetTester tester, {
    required NoteStore store,
    required Note note,
  }) async {
    tester.view.physicalSize = const Size(1000, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('terminote_md_');
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
  }

  testWidgets('the B button bolds the selected text, and again undoes it', (
    tester,
  ) async {
    final store = NoteStore.empty();
    final note = store.add(title: 'Md', body: 'hello world', now: 100);
    await openEditor(tester, store: store, note: note);

    _bodyController(tester).selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 5,
    );
    await tester.tap(find.text('B'));
    await tester.pump();
    expect(_bodyController(tester).text, '**hello** world');

    await tester.tap(find.text('B'));
    await tester.pump();
    expect(_bodyController(tester).text, 'hello world');
  });

  testWidgets('the checklist button turns lines into a checklist', (
    tester,
  ) async {
    final store = NoteStore.empty();
    final note = store.add(title: 'Md', body: 'milk\neggs', now: 100);
    await openEditor(tester, store: store, note: note);

    _bodyController(tester).selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 9,
    );
    await tester.tap(find.text('☑'));
    await tester.pump();
    expect(_bodyController(tester).text, '- [ ] milk\n- [ ] eggs');
  });

  testWidgets('PREVIEW renders Markdown and EDIT brings the field back', (
    tester,
  ) async {
    final store = NoteStore.empty();
    final note = store.add(
      title: 'Md',
      body: '# Heading\n\nSome **bold** text\n\n- [ ] a task',
      now: 100,
    );
    await openEditor(tester, store: store, note: note);

    await tester.tap(find.text('PREVIEW'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('markdown-preview')),
      findsOneWidget,
    );
    expect(_bodyField(), findsNothing);
    // The rendered heading and bold text appear as rich text without
    // their markers.
    final previewText = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.textSpan?.toPlainText() ?? t.data ?? '')
        .join('\n');
    expect(previewText, contains('Heading'));
    expect(previewText, contains('Some bold text'));
    expect(previewText, contains('☐'));
    expect(previewText, isNot(contains('**bold**')));

    await tester.tap(find.text('EDIT'));
    await tester.pump();
    expect(_bodyField(), findsOneWidget);
    expect(_bodyController(tester).text, contains('**bold**'));
  });

  testWidgets('formatting buttons are off while previewing', (tester) async {
    final store = NoteStore.empty();
    final note = store.add(title: 'Md', body: 'plain', now: 100);
    await openEditor(tester, store: store, note: note);

    await tester.tap(find.text('PREVIEW'));
    await tester.pump();
    final boldButton = tester.widget<TextButton>(
      find.ancestor(of: find.text('B'), matching: find.byType(TextButton)),
    );
    expect(boldButton.onPressed, isNull);
  });
}
