// Tests for the TermiNote data layer (lib/note_store.dart).
// Run with: flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/note_store.dart';

/// The exact shape TermiNote 0.1.0 wrote, including a field this version
/// does not know about (which must be ignored, not fatal).
const String v010Fixture = '''
{"next_id": 4,
 "future_field": {"anything": true},
 "notes": [
   {"id": 1, "title": "Shopping list", "body": "milk and eggs",
    "tags": ["home", "food"], "pinned": true, "created": 100, "modified": 300},
   {"id": 2, "title": "Work ideas", "body": "secret body text",
    "tags": ["work"], "pinned": false, "created": 200, "modified": 200},
   {"id": 3, "title": "Loose thought", "body": "",
    "tags": [], "pinned": false, "created": 150, "modified": 150}
 ],
 "trash": [
   {"id": 9, "title": "Old note", "body": "gone", "tags": [],
    "pinned": false, "created": 10, "modified": 10}
 ]}
''';

NoteStore seeded() {
  final store = NoteStore.empty();
  store.add(
    title: 'Shopping list',
    body: 'milk and eggs',
    tags: <String>['home', 'food'],
    now: 100,
  );
  store.add(
    title: 'Work ideas',
    body: 'secret body text',
    tags: <String>['work'],
    now: 200,
  );
  store.add(title: 'Loose thought', now: 150);
  return store;
}

void main() {
  group('v0.1.0 format compatibility', () {
    test('reads the 0.1.0 fixture, ignoring unknown fields', () {
      final store = NoteStore.fromJson(jsonDecode(v010Fixture));
      expect(store.notes, hasLength(3));
      expect(store.trash, hasLength(1));
      expect(store.get(1)!.title, 'Shopping list');
      expect(store.get(1)!.tags, <String>['home', 'food']);
      expect(store.get(1)!.pinned, isTrue);
      expect(store.getTrashed(9)!.title, 'Old note');
    });

    test('next_id stays ahead of every loaded id, trash included', () {
      final store = NoteStore.fromJson(jsonDecode(v010Fixture));
      // Stored next_id is 4 but the trash holds id 9, so the counter must
      // be repaired to 10: ids are never reused.
      expect(store.nextId, 10);
    });

    test('round-trips through JSON with the same field set', () {
      final store = NoteStore.fromJson(jsonDecode(v010Fixture));
      final again = NoteStore.fromJson(
        jsonDecode(const JsonEncoder().convert(store.toJson())),
      );
      expect(again.notes.map((n) => n.id), <int>[1, 2, 3]);
      expect(again.get(2)!.body, 'secret body text');
      final map = store.toJson();
      expect(
        map.keys,
        containsAll(<String>['next_id', 'notes', 'trash', 'order']),
      );
      final noteMap = (map['notes'] as List).first as Map;
      expect(
        noteMap.keys,
        containsAll(<String>[
          'id',
          'title',
          'body',
          'tags',
          'pinned',
          'created',
          'modified',
        ]),
      );
    });
  });

  group('tags', () {
    test('normalisation trims, lowercases, dedupes, drops empties', () {
      expect(
        normalizeTags(<String>[' Home ', 'HOME', '', '  ', 'Food']),
        <String>['home', 'food'],
      );
    });

    test('normalisation caps a tag at 40 characters', () {
      final tag = normalizeTag('a' * 50);
      expect(tag.length, 40);
    });

    test('parseTags splits on commas', () {
      expect(parseTags('a, b ,C'), <String>['a', 'b', 'c']);
    });

    test('renameTag merges onto an existing tag without duplicates', () {
      final store = seeded();
      final count = store.renameTag('food', 'home', now: 500);
      expect(count, 1);
      expect(store.get(1)!.tags, <String>['home']);
    });
  });

  group('operations', () {
    test('add allocates increasing ids and stamps both times', () {
      final store = NoteStore.empty();
      final a = store.add(title: 'One', now: 42);
      final b = store.add(title: 'Two', now: 43);
      expect(a.id, 1);
      expect(b.id, 2);
      expect(a.created, 42);
      expect(a.modified, 42);
      expect(store.nextId, 3);
    });

    test('add turns an empty title into Untitled note', () {
      final store = NoteStore.empty();
      expect(store.add(title: '   ', now: 1).title, 'Untitled note');
    });

    test('update only bumps modified when something changed', () {
      final store = seeded();
      store.update(1, title: 'Shopping list', now: 999);
      expect(store.get(1)!.modified, 300 - 200); // unchanged: still 100
      store.update(1, body: 'milk, eggs, bread', now: 999);
      expect(store.get(1)!.modified, 999);
    });

    test('delete moves to trash and restore brings it back', () {
      final store = seeded();
      expect(store.delete(2), isTrue);
      expect(store.get(2), isNull);
      expect(store.getTrashed(2)!.title, 'Work ideas');
      expect(store.restore(2), isTrue);
      expect(store.get(2)!.title, 'Work ideas');
      expect(store.delete(12345), isFalse);
    });

    test('deleteForever and emptyTrash remove trashed notes for good', () {
      final store = seeded();
      store.delete(1);
      store.delete(2);
      expect(store.deleteForever(1), isTrue);
      expect(store.trash, hasLength(1));
      store.emptyTrash();
      expect(store.trash, isEmpty);
    });

    test('deleteAll moves everything and reports the count', () {
      final store = seeded();
      expect(store.deleteAll(), 3);
      expect(store.notes, isEmpty);
      expect(store.trash, hasLength(3));
    });

    test('addTag and removeTag go through normalisation', () {
      final store = seeded();
      expect(store.addTag(3, ' Ideas ', now: 600), isTrue);
      expect(store.get(3)!.tags, <String>['ideas']);
      expect(store.removeTag(3, 'IDEAS', now: 700), isTrue);
      expect(store.get(3)!.tags, isEmpty);
      expect(store.removeTag(3, 'ideas', now: 800), isFalse);
    });

    test('setPinned toggles the flag', () {
      final store = seeded();
      expect(store.setPinned(2, pinned: true, now: 600), isTrue);
      expect(store.get(2)!.pinned, isTrue);
      expect(store.setPinned(999, pinned: true, now: 600), isFalse);
    });

    test('duplicate copies with a fresh id and a copy title', () {
      final store = seeded();
      final copy = store.duplicate(1, now: 600);
      expect(copy, isNotNull);
      expect(copy!.id, isNot(1));
      expect(copy.title, 'Shopping list copy');
      expect(copy.body, 'milk and eggs');
      expect(copy.tags, <String>['home', 'food']);
    });
  });

  group('list: filter, search, sort', () {
    test('search matches body text (results are titles for display)', () {
      final store = seeded();
      final found = store.list(search: 'milk');
      expect(found.map((n) => n.id), <int>[1]);
      final byTag = store.list(search: 'work');
      expect(byTag.map((n) => n.id), <int>[2]);
    });

    test('tag filter and untagged filter', () {
      final store = seeded();
      expect(store.list(tag: 'WORK').map((n) => n.id), <int>[2]);
      expect(store.list(untagged: true).map((n) => n.id), <int>[3]);
    });

    test('pinned notes come first under every sort', () {
      final store = seeded();
      store.setPinned(3, pinned: true, now: 50);
      expect(store.list().first.id, 3);
      expect(store.list(sort: SortMode.titleAsc).first.id, 3);
    });

    test('sort orders: modified desc, title asc, created desc', () {
      final store = seeded();
      expect(store.list().map((n) => n.id), <int>[2, 3, 1]);
      expect(store.list(sort: SortMode.titleAsc).map((n) => n.title), <String>[
        'Loose thought',
        'Shopping list',
        'Work ideas',
      ]);
      expect(store.list(sort: SortMode.createdDesc).map((n) => n.id), <int>[
        2,
        3,
        1,
      ]);
    });

    test('manual sort follows reorder(), and order survives JSON', () {
      final store = seeded();
      store.reorder(<int>[3, 1, 2]);
      expect(store.list(sort: SortMode.manual).map((n) => n.id), <int>[
        3,
        1,
        2,
      ]);
      final again = NoteStore.fromJson(
        jsonDecode(const JsonEncoder().convert(store.toJson())),
      );
      expect(again.list(sort: SortMode.manual).map((n) => n.id), <int>[
        3,
        1,
        2,
      ]);
    });
  });

  group('export and import', () {
    test('import merges with fresh ids and never overwrites', () {
      final source = seeded();
      final target = NoteStore.empty();
      target.add(title: 'Already here', body: 'mine', now: 50);
      final result = target.importJson(source.exportJson());
      expect(result.imported, 3);
      expect(result.skipped, 0);
      expect(target.notes, hasLength(4));
      final ids = target.notes.map((n) => n.id).toSet();
      expect(ids, hasLength(4));
    });

    test('import rejects text that is not a TermiNote export', () {
      final store = seeded();
      expect(() => store.importJson('{"hello": 1}'), throwsFormatException);
      expect(() => store.importJson('not json'), throwsFormatException);
    });

    test('importing the same export twice imports nothing the second '
        'time', () {
      final source = seeded();
      final target = NoteStore.empty();
      final first = target.importJson(source.exportJson());
      expect(first.imported, 3);
      expect(first.skipped, 0);
      final second = target.importJson(source.exportJson());
      expect(second.imported, 0);
      expect(second.skipped, 3);
      expect(target.notes, hasLength(3));
    });

    test('a same-title note with a changed body still imports', () {
      final target = NoteStore.empty();
      target.add(title: 'Shopping list', body: 'milk and eggs', now: 100);
      final changed = NoteStore.empty();
      changed.add(
        title: 'Shopping list',
        body: 'milk, eggs and bread',
        now: 100,
      );
      final result = target.importJson(changed.exportJson());
      expect(result.imported, 1);
      expect(result.skipped, 0);
      expect(target.notes, hasLength(2));
    });

    test('a duplicate that only exists in the trash still imports', () {
      final target = NoteStore.empty();
      final note = target.add(
        title: 'Shopping list',
        body: 'milk and eggs',
        now: 100,
      );
      target.delete(note.id);
      final source = NoteStore.empty();
      source.add(title: 'Shopping list', body: 'milk and eggs', now: 100);
      final result = target.importJson(source.exportJson());
      expect(result.imported, 1);
      expect(result.skipped, 0);
      expect(target.notes, hasLength(1));
      expect(target.trash, hasLength(1));
    });
  });

  group('stats', () {
    test('counts notes, trash, tags, pins, words, characters', () {
      final store = seeded();
      store.setPinned(1, pinned: true, now: 600);
      store.delete(3);
      final s = store.stats();
      expect(s.notes, 2);
      expect(s.trash, 1);
      expect(s.tags, 3);
      expect(s.pinned, 1);
      expect(s.words, greaterThan(0));
      expect(s.characters, greaterThan(0));
    });
  });

  group('markdown data files', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('terminote_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    String notesDir() => StoreFile.notesDirFor(dir.path);
    String trashDir() => StoreFile.trashDirFor(dir.path);

    List<String> mdNames(String folder) {
      final d = Directory(folder);
      if (!d.existsSync()) return <String>[];
      return d
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.endsWith('.md'))
          .toList()
        ..sort();
    }

    test(
      'save writes one .md file per note, and load reads them back',
      () async {
        final store = await StoreFile.load(dir.path);
        final a = store.add(
          title: 'Shopping list',
          body: 'milk and eggs',
          tags: <String>['home', 'food'],
          now: 100,
        );
        final b = store.add(
          title: 'Work ideas',
          body: 'secret body text',
          tags: <String>['work'],
          now: 200,
        );
        store.reorder(<int>[b.id, a.id]);
        await store.saveDirty();
        expect(mdNames(notesDir()), <String>[
          '1-shopping-list.md',
          '2-work-ideas.md',
        ]);
        // No temp files are left behind by the atomic writes.
        expect(
          Directory(
            notesDir(),
          ).listSync().where((e) => e.path.endsWith('.tmp')),
          isEmpty,
        );
        final loaded = await StoreFile.load(dir.path);
        expect(loaded.wasMissing, isFalse);
        expect(loaded.wasCorrupt, isFalse);
        expect(
          loaded.notes.map((n) => n.title),
          store.notes.map((n) => n.title),
        );
        expect(loaded.get(1)!.body, 'milk and eggs');
        expect(loaded.get(1)!.tags, <String>['home', 'food']);
        expect(loaded.order, <int>[2, 1]);
        expect(loaded.nextId, 3);
      },
    );

    test(
      'an empty data folder loads as an empty store flagged wasMissing',
      () async {
        final loaded = await StoreFile.load(dir.path);
        expect(loaded.wasMissing, isTrue);
        expect(loaded.notes, isEmpty);
      },
    );

    test('a 0.2.0 notes.json is migrated to .md files, backup kept', () async {
      File('${dir.path}/notes.json').writeAsStringSync(v010Fixture);
      final store = await StoreFile.load(dir.path);
      expect(store.notes, hasLength(3));
      expect(store.trash, hasLength(1));
      expect(store.get(1)!.title, 'Shopping list');
      expect(store.get(1)!.body, 'milk and eggs');
      expect(store.get(1)!.tags, <String>['home', 'food']);
      expect(store.get(1)!.pinned, isTrue);
      expect(store.getTrashed(9)!.title, 'Old note');
      // Ids are never reused: the trash holds id 9, so the next id is 10.
      expect(store.nextId, 10);
      // Every note became a file; the trash entry went to trash/.
      expect(mdNames(notesDir()), hasLength(3));
      expect(File('${notesDir()}/1-shopping-list.md').existsSync(), isTrue);
      expect(mdNames(trashDir()), <String>['9-old-note.md']);
      // The old file was renamed to the backup name, bytes untouched,
      // and never deleted.
      expect(File('${dir.path}/notes.json').existsSync(), isFalse);
      final backup = File('${dir.path}/notes.json.migrated.bak');
      expect(backup.existsSync(), isTrue);
      expect(backup.readAsStringSync(), v010Fixture);
      // A second load reads the .md files (no re-migration).
      final again = await StoreFile.load(dir.path);
      expect(again.notes, hasLength(3));
      expect(again.trash, hasLength(1));
    });

    test('migration uses .bak2 when the first backup name is taken', () async {
      File('${dir.path}/notes.json').writeAsStringSync(v010Fixture);
      File(
        '${dir.path}/notes.json.migrated.bak',
      ).writeAsStringSync('older backup');
      final store = await StoreFile.load(dir.path);
      expect(store.notes, hasLength(3));
      expect(
        File('${dir.path}/notes.json.migrated.bak').readAsStringSync(),
        'older backup',
      );
      expect(File('${dir.path}/notes.json.migrated.bak2').existsSync(), isTrue);
    });

    test('a corrupt notes.json is quarantined during migration', () async {
      final path = '${dir.path}/notes.json';
      File(path).writeAsStringSync('{this is not json');
      final loaded = await StoreFile.load(dir.path, now: 4242);
      expect(loaded.wasCorrupt, isTrue);
      expect(loaded.notes, isEmpty);
      expect(File(path).existsSync(), isFalse);
      final quarantined = File('$path.corrupt-4242');
      expect(quarantined.existsSync(), isTrue);
      expect(quarantined.readAsStringSync(), '{this is not json');
    });

    test('a title change renames the note file and leaves no orphan', () async {
      final store = await StoreFile.load(dir.path);
      final note = store.add(title: 'Shopping list', body: 'milk', now: 100);
      await store.saveDirty();
      expect(File('${notesDir()}/1-shopping-list.md').existsSync(), isTrue);
      store.update(note.id, title: 'Groceries', now: 200);
      await store.saveDirty();
      expect(File('${notesDir()}/1-shopping-list.md').existsSync(), isFalse);
      final renamed = File('${notesDir()}/1-groceries.md');
      expect(renamed.existsSync(), isTrue);
      expect(renamed.readAsStringSync(), contains('title: Groceries'));
      expect(mdNames(notesDir()), <String>['1-groceries.md']);
    });

    test("editing one note does not rewrite another note's file", () async {
      final store = await StoreFile.load(dir.path);
      final a = store.add(title: 'First note', body: 'aaa', now: 100);
      final b = store.add(title: 'Second note', body: 'bbb', now: 100);
      await store.saveDirty();
      final bFile = File('${notesDir()}/${b.id}-second-note.md');
      final bContentBefore = bFile.readAsStringSync();
      final bModifiedBefore = bFile.lastModifiedSync();
      // Wait past a second so a rewrite of B would show in its timestamp.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      store.update(a.id, body: 'aaa changed', now: 200);
      await store.saveDirty();
      expect(bFile.readAsStringSync(), bContentBefore);
      expect(bFile.lastModifiedSync(), bModifiedBefore);
      expect(
        File('${notesDir()}/${a.id}-first-note.md').readAsStringSync(),
        contains('aaa changed'),
      );
    });

    test('delete moves the file to trash, restore moves it back, '
        'delete-forever removes it', () async {
      final store = await StoreFile.load(dir.path);
      final note = store.add(title: 'Doomed note', body: 'x', now: 100);
      await store.saveDirty();
      final live = File('${notesDir()}/1-doomed-note.md');
      final trashed = File('${trashDir()}/1-doomed-note.md');
      expect(live.existsSync(), isTrue);
      store.delete(note.id);
      await store.saveDirty();
      expect(live.existsSync(), isFalse);
      expect(trashed.existsSync(), isTrue);
      store.restore(note.id);
      await store.saveDirty();
      expect(live.existsSync(), isTrue);
      expect(trashed.existsSync(), isFalse);
      store.delete(note.id);
      await store.saveDirty();
      store.deleteForever(note.id);
      await store.saveDirty();
      expect(trashed.existsSync(), isFalse);
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes, isEmpty);
      expect(loaded.trash, isEmpty);
    });

    test('front matter round-trips: write then parse gives the same note', () {
      final note = Note(
        id: 3,
        title: 'Non-Negotiable',
        body: 'line one\nline two\n',
        tags: <String>['rules', 'home'],
        pinned: true,
        created: 1761674007,
        modified: 1761674325,
        order: 2,
      );
      final text = encodeNoteFile(note);
      expect(
        text,
        startsWith(
          '---\n'
          'id: 3\n'
          'title: Non-Negotiable\n'
          'tags: [rules, home]\n'
          'pinned: true\n'
          'created: 1761674007\n'
          'modified: 1761674325\n'
          'order: 2\n'
          '---\n'
          '\n',
        ),
      );
      final parsed = decodeNoteFile(text, fileName: '3-non-negotiable.md');
      expect(parsed.id, 3);
      expect(parsed.title, 'Non-Negotiable');
      expect(parsed.tags, <String>['rules', 'home']);
      expect(parsed.pinned, isTrue);
      expect(parsed.created, 1761674007);
      expect(parsed.modified, 1761674325);
      expect(parsed.order, 2);
      expect(parsed.body, 'line one\nline two\n');
    });

    test('titles with edge spaces round-trip through encode and decode', () {
      for (final title in <String>['trailing  ', '  both  ', 'back\\slash ']) {
        final note = Note(
          id: 5,
          title: title,
          body: 'body',
          tags: <String>[],
          pinned: false,
          created: 10,
          modified: 20,
        );
        final parsed = decodeNoteFile(
          encodeNoteFile(note),
          fileName: '5-note.md',
        );
        expect(parsed.title, title);
      }
    });

    test('a title with quotes in the middle is written plain and '
        'reads back unchanged', () {
      final note = Note(
        id: 5,
        title: 'say "hi"',
        body: 'body',
        tags: <String>[],
        pinned: false,
        created: 10,
        modified: 20,
      );
      final text = encodeNoteFile(note);
      expect(text, contains('title: say "hi"\n'));
      expect(decodeNoteFile(text, fileName: '5-note.md').title, 'say "hi"');
    });

    test('a title wrapped in quotes round-trips too', () {
      final note = Note(
        id: 5,
        title: '"quoted"',
        body: 'body',
        tags: <String>[],
        pinned: false,
        created: 10,
        modified: 20,
      );
      final parsed = decodeNoteFile(
        encodeNoteFile(note),
        fileName: '5-note.md',
      );
      expect(parsed.title, '"quoted"');
    });

    test('a title with trailing spaces survives a save and load', () async {
      final store = await StoreFile.load(dir.path);
      store.add(title: 'Shopping list  ', body: 'milk', now: 100);
      await store.saveDirty();
      final file = File('${notesDir()}/1-shopping-list.md');
      expect(file.readAsStringSync(), contains('title: "Shopping list  "'));
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes.single.title, 'Shopping list  ');
    });

    test('an old unquoted file still loads its title as before', () async {
      Directory(notesDir()).createSync(recursive: true);
      File('${notesDir()}/2-plain-title.md').writeAsStringSync(
        '---\n'
        'id: 2\n'
        'title: Plain title\n'
        'tags: []\n'
        'pinned: false\n'
        'created: 10\n'
        'modified: 20\n'
        'order: 0\n'
        '---\n'
        '\n'
        'the body',
      );
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes.single.title, 'Plain title');
      expect(loaded.notes.single.body, 'the body');
    });

    test('a file without front matter keeps its whole text as the body', () {
      final parsed = decodeNoteFile(
        'Hello world\nsome body\n',
        fileName: '7-loose.md',
        fileModifiedSeconds: 555,
      );
      expect(parsed.id, 7);
      expect(parsed.title, 'Hello world');
      expect(parsed.body, 'Hello world\nsome body\n');
      expect(parsed.created, 555);
      expect(parsed.modified, 555);
    });

    test('resolveDataDir honours a TERMINOTE_DATA file path override', () {
      final dataDir = StoreFile.resolveDataDir(
        environment: <String, String>{'TERMINOTE_DATA': '/somewhere/x.json'},
        executablePath: '/apps/TermiNote.exe',
      );
      expect(dataDir, '/somewhere');
    });

    test('resolveDataDir uses the exe folder in portable mode', () {
      File('${dir.path}/portable.txt').writeAsStringSync('');
      final dataDir = StoreFile.resolveDataDir(
        environment: <String, String>{},
        executablePath: '${dir.path}/TermiNote.exe',
      );
      expect(dataDir, dir.path);
    });
  });

  group('notes folder backup and restore', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('terminote_backup_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test(
      'backup and restore round trip keeps notes, trash, and details',
      () async {
        final store = NoteStore.empty()
          ..notesDir = StoreFile.notesDirFor('${dir.path}/data');
        final live = store.add(
          title: 'Keep me',
          body: 'live body',
          tags: <String>['x'],
          now: 100,
        );
        store.setPinned(live.id, pinned: true, now: 100);
        final gone = store.add(title: 'Gone', body: 'trash body', now: 200);
        store.delete(gone.id);
        await store.saveDirty();

        final backupFolder = '${dir.path}/backup';
        final copied = await store.backupNotesTo(backupFolder);
        expect(copied, 2);
        expect(File('$backupFolder/notes/1-keep-me.md').existsSync(), isTrue);
        expect(
          File('$backupFolder/notes/trash/2-gone.md').existsSync(),
          isTrue,
        );

        // Restore into a store that already has a note of its own, so
        // the restored notes must arrive with fresh ids.
        final fresh = NoteStore.empty()
          ..notesDir = StoreFile.notesDirFor('${dir.path}/other');
        fresh.add(title: 'Already here', body: 'mine', now: 50);
        final result = await fresh.restoreNotesFrom(backupFolder);
        expect(result.restored, 2);
        expect(result.skipped, 0);
        expect(fresh.notes, hasLength(2));
        final restoredLive = fresh.notes.last;
        expect(restoredLive.title, 'Keep me');
        expect(restoredLive.body, 'live body');
        expect(restoredLive.tags, <String>['x']);
        expect(restoredLive.pinned, isTrue);
        expect(restoredLive.created, 100);
        expect(restoredLive.id, isNot(live.id));
        expect(fresh.trash.single.title, 'Gone');
        expect(fresh.trash.single.body, 'trash body');
        expect(fresh.trash.single.id, isNot(gone.id));

        // And the restored notes save and reload like any others.
        await fresh.saveDirty();
        final reloaded = await StoreFile.load('${dir.path}/other');
        expect(reloaded.notes.map((n) => n.title), contains('Keep me'));
        expect(reloaded.trash.single.title, 'Gone');
      },
    );

    test('backing up into the notes folder itself is refused', () async {
      final store = NoteStore.empty()
        ..notesDir = StoreFile.notesDirFor(dir.path);
      store.add(title: 'X', body: 'x', now: 1);
      await store.saveDirty();
      final notes = StoreFile.notesDirFor(dir.path);
      // The notes folder itself.
      await expectLater(store.backupNotesTo(notes), throwsArgumentError);
      // A folder inside the notes folder.
      await expectLater(
        store.backupNotesTo('$notes/inside'),
        throwsArgumentError,
      );
      // The data folder: its notes subfolder IS the notes folder.
      await expectLater(store.backupNotesTo(dir.path), throwsArgumentError);
    });

    test('restore counts files it cannot read as skipped', () async {
      final backupFolder = '${dir.path}/backup';
      Directory('$backupFolder/notes').createSync(recursive: true);
      File('$backupFolder/notes/1-good.md').writeAsStringSync(
        '---\n'
        'id: 1\n'
        'title: Good\n'
        'tags: []\n'
        'pinned: false\n'
        'created: 10\n'
        'modified: 20\n'
        'order: 0\n'
        '---\n'
        '\n'
        'fine',
      );
      // Bytes that are not valid UTF-8: the file cannot be read as text.
      File(
        '$backupFolder/notes/2-broken.md',
      ).writeAsBytesSync(<int>[0xFF, 0xFE, 0x41, 0xC3, 0x28]);
      final store = NoteStore.empty();
      final result = await store.restoreNotesFrom(backupFolder);
      expect(result.restored, 1);
      expect(result.skipped, 1);
      expect(store.notes.single.title, 'Good');
    });

    test('restore from a folder with no notes folder fails', () async {
      final store = NoteStore.empty();
      await expectLater(
        store.restoreNotesFrom('${dir.path}/nowhere'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('list conversion', () {
    test('numbers plain lines in order', () {
      expect(toNumberedList('milk\neggs\nbread'), '1. milk\n2. eggs\n3. bread');
    });

    test('bullets plain lines', () {
      expect(toBulletList('milk\neggs'), '• milk\n• eggs');
    });

    test('blank lines stay blank and do not consume a number', () {
      expect(toNumberedList('milk\n\neggs'), '1. milk\n\n2. eggs');
      expect(toBulletList('milk\n\neggs'), '• milk\n\n• eggs');
    });

    test('a fully numbered list toggles back to plain text', () {
      expect(toNumberedList('1. milk\n2. eggs'), 'milk\neggs');
      expect(toNumberedList('1. milk\n2) eggs'), 'milk\neggs');
    });

    test('a fully bulleted list toggles back to plain text', () {
      expect(toBulletList('• milk\n• eggs'), 'milk\neggs');
    });

    test('bullets convert to numbers', () {
      expect(toNumberedList('• milk\n• eggs'), '1. milk\n2. eggs');
    });

    test('numbers convert to bullets', () {
      expect(toBulletList('1. milk\n12) eggs'), '• milk\n• eggs');
    });

    test('a new plain line renumbers the whole list', () {
      expect(toNumberedList('new\n1. a\n2. b'), '1. new\n2. a\n3. b');
    });

    test('strip removes every marker kind and leaves plain text alone', () {
      expect(
        stripListMarkers(
          '• milk\n- eggs\n* bread\n1. jam\n12) ham\nplain\n'
          '1.5 litres of water',
        ),
        'milk\neggs\nbread\njam\nham\nplain\n1.5 litres of water',
      );
    });

    test('an empty list item keeps its place in the numbering', () {
      expect(toNumberedList('a\n2.\nb'), '1. a\n2.\n3. b');
    });

    test('empty text stays empty', () {
      expect(toNumberedList(''), '');
      expect(toBulletList(''), '');
      expect(stripListMarkers(''), '');
    });
  });
}
