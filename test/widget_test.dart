// Widget test for the list screen.
//
// The key rule of the whole program: the list shows note TITLES ONLY.
// This test pumps the real list screen with notes whose body text is
// unique and unmistakable, and asserts that text appears nowhere.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
    final state = AppState(store: store, dataDir: dir.path);

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

  testWidgets('closing a dirty editor asks first', (tester) async {
    final dir = Directory.systemTemp.createTempSync('terminote_widget_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    // A file-backed store in the temp folder. Saving is asynchronous
    // now, so the write runs inside runAsync, where real file IO is
    // allowed to complete.
    final store = NoteStore.empty()..notesDir = StoreFile.notesDirFor(dir.path);
    store.add(title: 'Existing note', body: 'original body text', now: 100);
    await tester.runAsync(() => store.saveDirty());
    final state = AppState(store: store, dataDir: dir.path);

    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));

    // Open the editor and change the body text. The dirty check is a
    // synchronous snapshot comparison, so the dialog path below does
    // not depend on the 600 ms autosave debounce having fired — the
    // pumps after the edit stay well under it on purpose.
    await tester.tap(find.text('Existing note'));
    await tester.pumpAndSettle();
    final bodyField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'original body text',
    );
    expect(bodyField, findsOneWidget);
    await tester.enterText(bodyField, 'changed body text');

    // Back with unsaved changes: the confirmation dialog appears.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Save before closing?'), findsOneWidget);

    // "Keep editing": the dialog goes away and the editor stays open.
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Save before closing?'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'changed body text',
      ),
      findsOneWidget,
    );

    // Edit once more so the note is dirty again (the pumps above let
    // the autosave debounce fire, which is the app working as meant),
    // then back and "Save and close": the editor closes and the change
    // is in the note's Markdown file on disk. The save is asynchronous,
    // so give the real file write time to land before checking the list
    // and the file.
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'changed body text',
      ),
      'changed body text again',
    );
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Save before closing?'), findsOneWidget);
    await tester.tap(find.text('Save and close'));
    // The save writes the file in several real-IO steps whose
    // continuations land back in the test's fake-async zone, so real
    // time and fake pumps have to alternate until the chain drains.
    // (Plain pumps, not pumpAndSettle: back on the list, the blinking
    // header cursor animates forever and never settles.)
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Existing note'), findsOneWidget);
    final noteFile = File(
      '${StoreFile.notesDirFor(dir.path)}/1-existing-note.md',
    );
    expect(noteFile.readAsStringSync(), contains('changed body text again'));
  });

  testWidgets('a clean editor closes without asking', (tester) async {
    final dir = Directory.systemTemp.createTempSync('terminote_widget_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = NoteStore.empty();
    store.add(title: 'Existing note', body: 'original body text', now: 100);
    final state = AppState(store: store, dataDir: dir.path);

    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('Existing note'));
    await tester.pumpAndSettle();

    // No edits, so the back arrow closes straight away — no dialog.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Save before closing?'), findsNothing);
    // Two plain pumps rather than pumpAndSettle: back on the list, the
    // blinking header cursor animates forever and never settles.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Existing note'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  test('minimizeToTray defaults on and persists when switched off', () async {
    final dir = Directory.systemTemp.createTempSync('terminote_widget_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final fresh = AppState(store: NoteStore.empty(), dataDir: dir.path);
    expect(fresh.minimizeToTray, isTrue);

    final off = AppState(
      store: NoteStore.empty(),
      dataDir: dir.path,
      minimizeToTray: false,
    );
    await off.saveSettings();
    final decoded =
        jsonDecode(File(AppState.settingsPathFor(dir.path)).readAsStringSync())
            as Map<String, dynamic>;
    expect(decoded['minimize_to_tray'], isFalse);
  });

  testWidgets('empty store shows the terminal empty state', (tester) async {
    final dir = Directory.systemTemp.createTempSync('terminote_widget_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final state = AppState(store: NoteStore.empty(), dataDir: dir.path);
    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('> no notes yet'), findsOneWidget);
    expect(
      find.text('Press Add note to write your first one.'),
      findsOneWidget,
    );
  });
}
