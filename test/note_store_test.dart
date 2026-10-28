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
      final target = seeded();
      final count = target.importJson(source.exportJson());
      expect(count, 3);
      expect(target.notes, hasLength(6));
      final ids = target.notes.map((n) => n.id).toSet();
      expect(ids, hasLength(6));
    });

    test('import rejects text that is not a TermiNote export', () {
      final store = seeded();
      expect(() => store.importJson('{"hello": 1}'), throwsFormatException);
      expect(() => store.importJson('not json'), throwsFormatException);
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

  group('data file', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('terminote_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('save then load round-trips the whole store', () {
      final path = '${dir.path}/notes.json';
      final store = seeded();
      store.reorder(<int>[2, 1, 3]);
      StoreFile.save(path, store);
      final loaded = StoreFile.load(path);
      expect(loaded.wasMissing, isFalse);
      expect(loaded.wasCorrupt, isFalse);
      expect(loaded.notes.map((n) => n.title), store.notes.map((n) => n.title));
      expect(loaded.order, <int>[2, 1, 3]);
      expect(File('$path.tmp').existsSync(), isFalse);
    });

    test('missing file loads as an empty store flagged wasMissing', () {
      final loaded = StoreFile.load('${dir.path}/nope.json');
      expect(loaded.wasMissing, isTrue);
      expect(loaded.notes, isEmpty);
    });

    test('a corrupt file is quarantined, not overwritten', () {
      final path = '${dir.path}/notes.json';
      File(path).writeAsStringSync('{this is not json');
      final loaded = StoreFile.load(path, now: 4242);
      expect(loaded.wasCorrupt, isTrue);
      expect(loaded.notes, isEmpty);
      expect(File(path).existsSync(), isFalse);
      final quarantined = File('$path.corrupt-4242');
      expect(quarantined.existsSync(), isTrue);
      expect(quarantined.readAsStringSync(), '{this is not json');
    });

    test('resolvePath honours the TERMINOTE_DATA override', () {
      final path = StoreFile.resolvePath(
        environment: <String, String>{'TERMINOTE_DATA': '/somewhere/x.json'},
        executablePath: '/apps/TermiNote.exe',
      );
      expect(path, '/somewhere/x.json');
    });

    test('resolvePath uses the exe folder in portable mode', () {
      File('${dir.path}/portable.txt').writeAsStringSync('');
      final path = StoreFile.resolvePath(
        environment: <String, String>{},
        executablePath: '${dir.path}/TermiNote.exe',
      );
      expect(path, '${dir.path}${Platform.pathSeparator}notes.json');
    });
  });
}
