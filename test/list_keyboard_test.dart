// Widget tests for keyboard control of the note list: arrow keys move
// a highlight between cards (the same card the mouse would hover),
// Enter opens the highlighted note, and Delete trashes it with the
// usual undo snackbar. While the search field has the focus, the keys
// belong to the field and do none of this.
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';

/// The card carrying the keyboard highlight, found through the
/// selected flag on the card's semantics — no pixel checks.
Finder _highlightedCard(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.selected == true,
  ),
);

Finder _anyHighlightedCard() => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.selected == true,
);

/// A store with three notes; newest-changed-first order on screen is
/// Third note, Second note, First note.
NoteStore _threeNotes() {
  final store = NoteStore.empty();
  store.add(title: 'First note', body: 'body one', now: 100);
  store.add(title: 'Second note', body: 'body two', now: 200);
  store.add(title: 'Third note', body: 'body three', now: 300);
  return store;
}

Future<AppState> _pumpList(WidgetTester tester, NoteStore store) async {
  final dir = Directory.systemTemp.createTempSync('terminote_keys_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final state = AppState(store: store, dataDir: dir.path);
  await tester.pumpWidget(TermiNoteApp(state: state));
  await tester.pump(const Duration(milliseconds: 120));
  return state;
}

void main() {
  testWidgets('arrow keys move the highlight and stop at the ends', (
    tester,
  ) async {
    await _pumpList(tester, _threeNotes());
    expect(_anyHighlightedCard(), findsNothing);

    // First Down highlights the first card.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlightedCard('Third note'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlightedCard('Second note'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlightedCard('First note'), findsOneWidget);

    // Down at the last card stays there.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlightedCard('First note'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_highlightedCard('Second note'), findsOneWidget);
  });

  testWidgets('first Up highlights the last card', (tester) async {
    await _pumpList(tester, _threeNotes());
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_highlightedCard('First note'), findsOneWidget);
  });

  testWidgets('hovering a card moves the highlight to it', (tester) async {
    await _pumpList(tester, _threeNotes());
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(find.text('Second note')));
    await tester.pump();
    expect(_highlightedCard('Second note'), findsOneWidget);

    // And the arrow keys continue from the hovered card.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlightedCard('First note'), findsOneWidget);
    await gesture.removePointer();
  });

  testWidgets('Enter opens the highlighted note', (tester) async {
    await _pumpList(tester, _threeNotes());
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlightedCard('Second note'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    // The editor is open on the second note.
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'body two',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Delete trashes the highlighted note, with undo', (tester) async {
    final store = _threeNotes();
    await _pumpList(tester, store);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlightedCard('Third note'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(store.notes.map((n) => n.title), <String>[
      'First note',
      'Second note',
    ]);
    expect(store.trash.single.title, 'Third note');
    expect(find.text('Note deleted.'), findsOneWidget);
    expect(find.text('UNDO'), findsOneWidget);

    // The highlight lands on the note that followed the deleted one.
    expect(_highlightedCard('Second note'), findsOneWidget);

    // Undo brings it back, like the card button's snackbar. (Let the
    // snackbar finish sliding in first, so the tap lands on it.)
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('UNDO'));
    await tester.pump();
    expect(store.notes, hasLength(3));
    expect(store.trash, isEmpty);
  });

  testWidgets('keys do nothing while the search field is focused', (
    tester,
  ) async {
    final store = _threeNotes();
    await _pumpList(tester, store);
    await tester.tap(find.byTooltip('Search notes (Ctrl+F)'));
    await tester.pump(const Duration(milliseconds: 300));
    final searchField = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Search titles, tags, text',
    );
    expect(searchField, findsOneWidget);
    await tester.enterText(searchField, 'Second');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_anyHighlightedCard(), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(store.notes, hasLength(3));
    expect(store.trash, isEmpty);
  });
}
