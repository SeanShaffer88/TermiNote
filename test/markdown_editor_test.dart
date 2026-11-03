// Widget tests for the Markdown editor slice: the formatting toolbar
// wraps the selection, and the Preview switch renders the note and
// switches back.
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

  testWidgets('SPLIT shows the editor and the rendered preview together', (
    tester,
  ) async {
    final store = NoteStore.empty();
    final note = store.add(title: 'Md', body: 'Some **bold** text', now: 100);
    await openEditor(tester, store: store, note: note);

    await tester.tap(find.text('SPLIT'));
    await tester.pump();
    expect(_bodyField(), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('markdown-preview')),
      findsOneWidget,
    );
    final previewText = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.textSpan?.toPlainText() ?? t.data ?? '')
        .join('\n');
    expect(previewText, contains('Some bold text'));
  });

  testWidgets('PREVIEW renders a table as a grid', (tester) async {
    final store = NoteStore.empty();
    final note = store.add(
      title: 'Md',
      body: '| Name | Role |\n| --- | --- |\n| Ada | Lead |',
      now: 100,
    );
    await openEditor(tester, store: store, note: note);

    await tester.tap(find.text('PREVIEW'));
    await tester.pump();
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
    expect(find.text('Lead'), findsOneWidget);
  });

  testWidgets('the outline strip lists headings and jumps to one', (
    tester,
  ) async {
    final store = NoteStore.empty();
    final note = store.add(
      title: 'Md',
      body: '# Top\nbody\n## Later\nmore',
      now: 100,
    );
    await openEditor(tester, store: store, note: note);

    expect(find.byKey(const ValueKey<String>('outline-strip')), findsOneWidget);
    await tester.tap(find.text('## Later'));
    await tester.pump();
    final selection = _bodyController(tester).selection;
    expect(
      _bodyController(tester).text.substring(selection.start),
      startsWith('## Later'),
    );
  });

  testWidgets('typing ( auto-pairs it and ;date expands in the editor', (
    tester,
  ) async {
    final store = NoteStore.empty();
    final note = store.add(title: 'Md', body: '', now: 100);
    await openEditor(tester, store: store, note: note);

    await tester.tap(_bodyField());
    await tester.enterText(_bodyField(), '(');
    await tester.pump();
    expect(_bodyController(tester).text, '()');

    _bodyController(tester).value = const TextEditingValue(
      text: ';date',
      selection: TextSelection.collapsed(offset: 5),
    );
    await tester.pump();
    expect(_bodyController(tester).text, isNot(contains(';date')));
    expect(
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(_bodyController(tester).text),
      isTrue,
    );
  });

  testWidgets('find and replace swaps the words in the body', (tester) async {
    final store = NoteStore.empty();
    final note = store.add(title: 'Md', body: 'cat and cat', now: 100);
    await openEditor(tester, store: store, note: note);

    // Ctrl+F, the way a keyboard would send it.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('find-field')),
      'cat',
    );
    await tester.pump();
    expect(find.text('match 1 of 2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.find_replace));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('replace-field')),
      'dog',
    );
    await tester.tap(find.text('Replace all'));
    await tester.pump();
    expect(_bodyController(tester).text, 'dog and dog');
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
