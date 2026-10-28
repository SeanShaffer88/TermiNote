// Widget test for the list screen.
//
// The key rule of the whole program: the list shows note TITLES ONLY.
// This test pumps the real list screen with notes whose body text is
// unique and unmistakable, and asserts that text appears nowhere.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';

void main() {
  testWidgets('list shows titles only, never body text', (tester) async {
    final dir = Directory.systemTemp.createTempSync('terminote_widget_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = NoteStore.empty();
    store.add(
      title: 'Shopping list',
      body: 'zqx-secret-body-one milk and eggs',
      tags: <String>['home'],
      now: 100,
    );
    store.add(
      title: 'Work ideas',
      body: 'zqx-secret-body-two launch plans',
      tags: <String>['work'],
      now: 200,
    );
    final state = AppState(store: store, dataPath: '${dir.path}/notes.json');

    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));

    // Both titles are on screen.
    expect(find.text('Shopping list'), findsOneWidget);
    expect(find.text('Work ideas'), findsOneWidget);

    // Neither body text is anywhere — not as a preview, not in a tooltip
    // dump, nowhere in the tree.
    expect(find.textContaining('zqx-secret-body-one'), findsNothing);
    expect(find.textContaining('zqx-secret-body-two'), findsNothing);
    expect(find.textContaining('milk and eggs'), findsNothing);
    expect(find.textContaining('launch plans'), findsNothing);

    // The toolbar from the design is there.
    expect(find.text('Add note'), findsOneWidget);
    expect(find.text('All Delete'), findsOneWidget);
    expect(find.text('All notes'), findsOneWidget);

    // Tag chips show on the cards.
    expect(find.text('home'), findsWidgets);
    expect(find.text('work'), findsWidgets);
  });

  testWidgets('empty store shows the terminal empty state', (tester) async {
    final dir = Directory.systemTemp.createTempSync('terminote_widget_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final state = AppState(
      store: NoteStore.empty(),
      dataPath: '${dir.path}/notes.json',
    );
    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('> no notes yet'), findsOneWidget);
    expect(
      find.text('Press Add note to write your first one.'),
      findsOneWidget,
    );
  });
}
