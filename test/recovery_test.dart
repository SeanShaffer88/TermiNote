// Tests for crash-recovery drafts.
//
// Store level: a draft is offered at load when its text differs from
// the saved note and its file is at least as new as the note's file;
// identical, stale, and orphan drafts are cleaned up instead. Widget
// level: the startup dialog offers the draft, Recover applies it,
// Discard throws it away, and the editor writes a draft as it
// autosaves and removes it on a clean close.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';

NoteStore _fileStore(Directory dir) => NoteStore.empty()
  ..notesDir = StoreFile.notesDirFor(dir.path)
  ..recoveryDir = StoreFile.recoveryDirFor(dir.path);

File _draftFile(Directory dir, int id) =>
    File('${StoreFile.recoveryDirFor(dir.path)}/recovery-$id.md');

void main() {
  group('recovery drafts (store)', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('terminote_recovery_');
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('a newer draft with different text is offered', () async {
      final store = _fileStore(dir);
      final note = store.add(title: 'Crash note', body: 'saved body', now: 100);
      await store.saveDirty();
      await store.saveRecoveryDraft(note.copy()..body = 'typed after the save');
      expect(_draftFile(dir, note.id).existsSync(), isTrue);

      final offered = await store.loadRecoveryDrafts();
      expect(offered, hasLength(1));
      expect(offered.single.id, note.id);
      expect(offered.single.body, 'typed after the save');
      // The offer does not consume the draft: the file stays until the
      // user answers.
      expect(_draftFile(dir, note.id).existsSync(), isTrue);
    });

    test('an identical draft is not offered and is cleaned up', () async {
      final store = _fileStore(dir);
      final note = store.add(title: 'Crash note', body: 'saved body', now: 100);
      await store.saveDirty();
      await store.saveRecoveryDraft(note.copy());
      expect(_draftFile(dir, note.id).existsSync(), isTrue);

      expect(await store.loadRecoveryDrafts(), isEmpty);
      expect(_draftFile(dir, note.id).existsSync(), isFalse);
    });

    test('a draft whose note is gone is dropped silently', () async {
      final store = _fileStore(dir);
      final note = store.add(title: 'Crash note', body: 'saved body', now: 100);
      await store.saveDirty();
      await store.saveRecoveryDraft(note.copy()..body = 'typed after the save');
      store.delete(note.id);
      store.deleteForever(note.id);
      await store.saveDirty();

      expect(await store.loadRecoveryDrafts(), isEmpty);
      expect(_draftFile(dir, note.id).existsSync(), isFalse);
    });

    test('a stale draft is not offered: the note was saved later', () async {
      final store = _fileStore(dir);
      final note = store.add(title: 'Crash note', body: 'saved body', now: 100);
      await store.saveDirty();
      await store.saveRecoveryDraft(note.copy()..body = 'typed after the save');
      // The note is saved again afterwards, and its file is stamped
      // clearly later than the draft, so the draft is stale.
      store.update(note.id, body: 'saved even later', now: 200);
      await store.saveDirty();
      final noteFile = File(
        '${StoreFile.notesDirFor(dir.path)}/${note.fileName}',
      );
      await noteFile.setLastModified(
        DateTime.now().add(const Duration(seconds: 5)),
      );

      expect(await store.loadRecoveryDrafts(), isEmpty);
      expect(_draftFile(dir, note.id).existsSync(), isFalse);
    });

    test('discarding deletes the draft file', () async {
      final store = _fileStore(dir);
      final note = store.add(title: 'Crash note', body: 'saved body', now: 100);
      await store.saveDirty();
      await store.saveRecoveryDraft(note.copy()..body = 'typed after the save');
      await store.deleteRecoveryDraft(note.id);
      expect(_draftFile(dir, note.id).existsSync(), isFalse);
      expect(await store.loadRecoveryDrafts(), isEmpty);
    });

    test('recovering applies the draft text through the update', () async {
      final store = _fileStore(dir);
      final note = store.add(
        title: 'Crash note',
        body: 'saved body',
        tags: <String>['old'],
        now: 100,
      );
      await store.saveDirty();
      await store.saveRecoveryDraft(
        note.copy()
          ..body = 'recovered body'
          ..tags = <String>['new'],
      );
      final offered = await store.loadRecoveryDrafts();
      expect(offered, hasLength(1));
      final draft = offered.single;
      store.update(
        draft.id,
        title: draft.title,
        body: draft.body,
        tags: draft.tags,
        now: 300,
      );
      await store.deleteRecoveryDraft(draft.id);
      expect(store.get(note.id)?.body, 'recovered body');
      expect(store.get(note.id)?.tags, <String>['new']);
      expect(_draftFile(dir, note.id).existsSync(), isFalse);
    });

    test('an in-memory store keeps no drafts', () async {
      final store = NoteStore.empty();
      final note = store.add(title: 'Loose note', body: 'body', now: 100);
      await store.saveRecoveryDraft(note.copy()..body = 'changed');
      expect(await store.loadRecoveryDrafts(), isEmpty);
      await store.deleteRecoveryDraft(note.id); // must not throw
    });
  });

  group('recovery at startup (widget)', () {
    /// Builds the crash scene on disk: a saved note plus a newer,
    /// different recovery draft, then a fresh store loaded from disk
    /// exactly as a real start would load it.
    Future<NoteStore> crashScene(WidgetTester tester, Directory dir) async {
      final store = _fileStore(dir);
      final note = store.add(title: 'Crash note', body: 'saved body', now: 100);
      await tester.runAsync(() async {
        await store.saveDirty();
        await store.saveRecoveryDraft(note.copy()..body = 'recovered text');
      });
      final loaded = await tester.runAsync(() => StoreFile.load(dir.path));
      return loaded!;
    }

    /// Alternates real time and fake pumps until pending real file IO
    /// has drained (the pattern the other widget tests use), so the
    /// startup check and its saves complete.
    Future<void> drainIo(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('Recover applies the draft and deletes it', (tester) async {
      final dir = Directory.systemTemp.createTempSync('terminote_rec_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final loaded = await crashScene(tester, dir);
      final state = AppState(store: loaded, dataDir: dir.path);
      await tester.pumpWidget(TermiNoteApp(state: state));
      await drainIo(tester);
      expect(find.text('Recover unsaved work?'), findsOneWidget);

      await tester.tap(find.text('Recover'));
      await drainIo(tester);
      expect(find.text('Recover unsaved work?'), findsNothing);
      expect(loaded.notes.single.body, 'recovered text');
      expect(_draftFile(dir, loaded.notes.single.id).existsSync(), isFalse);
    });

    testWidgets('Discard keeps the saved note and deletes the draft', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('terminote_rec_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final loaded = await crashScene(tester, dir);
      final state = AppState(store: loaded, dataDir: dir.path);
      await tester.pumpWidget(TermiNoteApp(state: state));
      await drainIo(tester);
      expect(find.text('Recover unsaved work?'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await drainIo(tester);
      expect(find.text('Recover unsaved work?'), findsNothing);
      expect(loaded.notes.single.body, 'saved body');
      expect(_draftFile(dir, loaded.notes.single.id).existsSync(), isFalse);
    });
  });

  testWidgets('editing writes a draft; a clean close deletes it', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('terminote_rec_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = _fileStore(dir);
    final note = store.add(
      title: 'Drafted note',
      body: 'original body',
      now: 100,
    );
    await tester.runAsync(() => store.saveDirty());
    final state = AppState(store: store, dataDir: dir.path);

    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('Drafted note'));
    await tester.pumpAndSettle();

    // Type, then let the autosave debounce fire and the real file
    // writes drain: the draft file appears beside the note file.
    final bodyField = find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == 'original body',
    );
    await tester.enterText(bodyField, 'edited body');
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(_draftFile(dir, note.id).existsSync(), isTrue);

    // The check button saves and closes cleanly: the draft goes away.
    await tester.tap(find.byIcon(Icons.check));
    await tester.pump(const Duration(milliseconds: 500));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(_draftFile(dir, note.id).existsSync(), isFalse);
    expect(find.text('Drafted note'), findsOneWidget);
  });
}
