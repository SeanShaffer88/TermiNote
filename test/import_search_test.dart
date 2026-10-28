// Tests for the 0.4.0 store additions: importing a note from a file's
// text (drag-and-drop and the add-file command share it), the search
// text cache staying correct as notes change, and filePathFor.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/note_store.dart';

void main() {
  group('importFileText', () {
    test('a TermiNote-format file keeps title, tags, and pin', () {
      final store = NoteStore.empty();
      final text = encodeNoteFileForTest();
      final note = store.importFileText(
        text,
        fileName: '42-my-note.md',
        now: 900,
      );
      expect(note.title, 'Kept title');
      expect(note.tags, <String>['alpha', 'beta']);
      expect(note.pinned, isTrue);
      expect(note.body, 'the body');
      expect(note.id, isNot(42), reason: 'imported notes get fresh ids');
      expect(note.fileName, isNull, reason: 'the source file is never tracked');
      expect(note.modified, 900);
      expect(store.notes, hasLength(1));
    });

    test('a plain text file: first line is the title, all of it the body', () {
      final store = NoteStore.empty();
      final note = store.importFileText(
        'Shopping list\nmilk\neggs\n',
        fileName: 'list.txt',
        now: 5,
      );
      expect(note.title, 'Shopping list');
      expect(note.body, contains('milk'));
      expect(note.tags, isEmpty);
    });
  });

  group('search cache', () {
    test('matches stay correct after the note is edited', () {
      final store = NoteStore.empty();
      final note = store.add(title: 'Alpha', body: 'first draft', now: 1);
      expect(store.list(search: 'draft'), hasLength(1));
      expect(store.list(search: 'final'), isEmpty);
      store.update(note.id, body: 'final version', now: 2);
      expect(store.list(search: 'draft'), isEmpty);
      expect(store.list(search: 'final'), hasLength(1));
    });

    test('a renamed tag is searchable under its new name only', () {
      final store = NoteStore.empty();
      store.add(title: 'A', tags: <String>['food'], now: 1);
      expect(store.list(search: 'food'), hasLength(1));
      store.renameTag('food', 'home', now: 2);
      expect(store.list(search: 'food'), isEmpty);
      expect(store.list(search: 'home'), hasLength(1));
    });

    test('a query cannot match across two neighbouring tags', () {
      final store = NoteStore.empty();
      store.add(title: 'A', tags: <String>['ab', 'cd'], now: 1);
      // 'b c' spans the join between the two tags; it is in neither
      // tag, nor in the title or body, so it must not match.
      expect(store.list(search: 'b c'), isEmpty);
      expect(store.list(search: 'ab'), hasLength(1));
    });
  });

  group('filePathFor', () {
    test('live and trashed notes resolve into their folders', () async {
      final dir = Directory.systemTemp.createTempSync('terminote_path_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final store = NoteStore.empty()
        ..notesDir = StoreFile.notesDirFor(dir.path);
      final note = store.add(title: 'Pathy', body: 'x', now: 1);
      expect(store.filePathFor(note), isNull, reason: 'not saved yet');
      await store.saveDirty();
      final livePath = store.filePathFor(note);
      expect(livePath, isNotNull);
      expect(livePath, contains('notes'));
      expect(File(livePath!).existsSync(), isTrue);

      store.delete(note.id);
      await store.saveDirty();
      final trashPath = store.filePathFor(note);
      expect(trashPath, contains('trash'));
      expect(File(trashPath!).existsSync(), isTrue);
    });
  });
}

/// A note file in TermiNote's own format, produced by the real
/// encoder from a note with id 42.
String encodeNoteFileForTest() {
  return encodeNoteFile(
    Note(
      id: 42,
      title: 'Kept title',
      body: 'the body',
      tags: <String>['alpha', 'beta'],
      pinned: true,
      created: 100,
      modified: 200,
    ),
  );
}
