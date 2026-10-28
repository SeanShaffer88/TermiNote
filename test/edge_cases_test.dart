/// Edge-case and failure-condition tests: hostile or unusual note
/// files, format round trips that must not lose text, id collisions,
/// the one-time migration, and list conversion on real-world text.
/// These came out of a pre-release audit; each test names the case it
/// protects.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/note_store.dart';

void main() {
  group('adversarial round trips', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('terminote_adv_');
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    String notesDir() => StoreFile.notesDirFor(dir.path);

    Future<NoteStore> saveAndReload(NoteStore store) async {
      store.notesDir = notesDir();
      await store.saveDirty();
      return StoreFile.load(dir.path);
    }

    test('title with leading spaces and colon/brackets survives', () async {
      final store = NoteStore.empty();
      store.add(title: '  indented: [draft] idea', body: 'b', now: 5);
      final loaded = await saveAndReload(store);
      expect(loaded.notes.single.title, '  indented: [draft] idea');
    });

    test('emoji title survives, slug falls back safely', () async {
      final store = NoteStore.empty();
      store.add(title: '🎉🎉', body: 'b', now: 5);
      final loaded = await saveAndReload(store);
      expect(loaded.notes.single.title, '🎉🎉');
      final names = Directory(
        notesDir(),
      ).listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, hasLength(1));
      expect(names.single, contains('note'));
    });

    test('body starting with a fence line survives', () async {
      final store = NoteStore.empty();
      store.add(title: 't', body: '---\nnot a header\n---', now: 5);
      final loaded = await saveAndReload(store);
      expect(loaded.notes.single.body, '---\nnot a header\n---');
    });

    test('body with trailing blank lines survives', () async {
      final store = NoteStore.empty();
      store.add(title: 't', body: 'line\n\n\n', now: 5);
      final loaded = await saveAndReload(store);
      expect(loaded.notes.single.body, 'line\n\n\n');
    });

    test('whitespace-only body survives', () async {
      final store = NoteStore.empty();
      store.add(title: 't', body: '   \n  ', now: 5);
      final loaded = await saveAndReload(store);
      expect(loaded.notes.single.body, '   \n  ');
    });

    test('tags with hash and spaces survive', () async {
      final store = NoteStore.empty();
      store.add(title: 't', body: 'b', tags: ['my tag', '#hash'], now: 5);
      final loaded = await saveAndReload(store);
      expect(loaded.notes.single.tags, ['my tag', '#hash']);
    });

    test('a CRLF file written by hand loads with its text', () async {
      Directory(notesDir()).createSync(recursive: true);
      File('${notesDir()}/7-hand-made.md').writeAsStringSync(
        '---\r\nid: 7\r\ntitle: From Notepad\r\ntags: [a]\r\npinned: true\r\n'
        'created: 10\r\nmodified: 20\r\norder: 0\r\n---\r\n\r\nline one\r\nline two',
      );
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes.single.title, 'From Notepad');
      expect(loaded.notes.single.pinned, isTrue);
      expect(loaded.notes.single.body, contains('line one'));
      expect(loaded.notes.single.body, contains('line two'));
    });

    test('sloppy header fields do not crash the load', () async {
      Directory(notesDir()).createSync(recursive: true);
      File('${notesDir()}/3-sloppy.md').writeAsStringSync(
        '---\nid:3\ntitle: Sloppy\nunknownkey: whatever\norder: banana\n'
        'created: -5\n---\n\nbody text',
      );
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes.single.title, 'Sloppy');
      expect(loaded.notes.single.body, 'body text');
    });

    test('two files claiming the same id load as two notes', () async {
      Directory(notesDir()).createSync(recursive: true);
      File(
        '${notesDir()}/1-first.md',
      ).writeAsStringSync('---\nid: 1\ntitle: First\n---\n\none');
      File(
        '${notesDir()}/1-second.md',
      ).writeAsStringSync('---\nid: 1\ntitle: Second\n---\n\ntwo');
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes, hasLength(2));
      expect(loaded.notes.map((n) => n.id).toSet(), hasLength(2));
      await loaded.saveDirty();
      final names = Directory(
        notesDir(),
      ).listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names, hasLength(2));
    });

    test('migration gives every note a usable id', () async {
      File('${dir.path}/notes.json').writeAsStringSync(
        jsonEncode({
          'next_id': 1,
          'notes': [
            {
              'id': 0,
              'title': 'Zero',
              'body': 'z',
              'tags': <String>[],
              'pinned': false,
              'created': 1,
              'modified': 1,
            },
          ],
          'trash': <dynamic>[],
        }),
      );
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes.single.id, greaterThan(0));
      expect(loaded.nextId, greaterThan(loaded.notes.single.id));
    });

    test('deleteAll moves files into the trash folder', () async {
      final store = NoteStore.empty()..notesDir = notesDir();
      store.add(title: 'One', body: '1', now: 1);
      store.add(title: 'Two', body: '2', now: 2);
      await store.saveDirty();
      store.deleteAll();
      await store.saveDirty();
      expect(Directory(notesDir()).listSync().whereType<File>(), isEmpty);
      final trashFiles = Directory(
        StoreFile.trashDirFor(dir.path),
      ).listSync().whereType<File>();
      expect(trashFiles, hasLength(2));
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes, isEmpty);
      expect(loaded.trash, hasLength(2));
    });

    test('importing the same export twice adds nothing the second '
        'time', () async {
      final source = NoteStore.empty();
      source.add(title: 'X', body: 'x', now: 1);
      final exportText = source.exportJson();
      final store = NoteStore.empty()..notesDir = notesDir();
      final first = store.importJson(exportText);
      expect(first.imported, 1);
      expect(first.skipped, 0);
      final second = store.importJson(exportText);
      expect(second.imported, 0);
      expect(second.skipped, 1);
      await store.saveDirty();
      expect(store.notes, hasLength(1));
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes, hasLength(1));
    });

    test('a title with a slash produces a flat file name', () async {
      final store = NoteStore.empty();
      store.add(title: 'a/b\\c:d', body: 'b', now: 5);
      final loaded = await saveAndReload(store);
      expect(loaded.notes.single.title, 'a/b\\c:d');
      final names = Directory(
        notesDir(),
      ).listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names.single, isNot(contains('/')));
      expect(names.single, isNot(contains('\\')));
    });

    test(
      'an empty note file and a .md directory do not break loading',
      () async {
        Directory(notesDir()).createSync(recursive: true);
        File('${notesDir()}/4-empty.md').writeAsStringSync('');
        Directory('${notesDir()}/9-folder.md').createSync();
        final loaded = await StoreFile.load(dir.path);
        expect(loaded.notes, hasLength(1));
        expect(loaded.notes.single.body, '');
        expect(loaded.notes.single.id, 4);
      },
    );

    test('a prefix-less note file gets a fresh usable id', () async {
      Directory(notesDir()).createSync(recursive: true);
      File(
        '${notesDir()}/random-thoughts.md',
      ).writeAsStringSync('just some text\nmore text');
      final loaded = await StoreFile.load(dir.path);
      expect(loaded.notes.single.id, greaterThan(0));
      expect(loaded.notes.single.body, contains('just some text'));
    });

    test('a very long title still makes a sane file name', () async {
      final store = NoteStore.empty();
      store.add(title: 'word ' * 100, body: 'b', now: 5);
      await saveAndReload(store);
      final names = Directory(
        notesDir(),
      ).listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names.single.length, lessThan(60));
    });
  });

  group('adversarial list conversion', () {
    test('mixed numbered and plain lines renumber cleanly', () {
      expect(
        toNumberedList('1. first\nplain\n9. third'),
        '1. first\n2. plain\n3. third',
      );
    });

    test('decimal numbers are not list markers', () {
      expect(toBulletList('1.5 litres of milk'), '• 1.5 litres of milk');
      expect(toNumberedList('1.5 litres of milk'), '1. 1.5 litres of milk');
    });

    test('windows line endings in the body convert cleanly', () {
      expect(toNumberedList('one\r\ntwo'), '1. one\n2. two');
    });

    test('empty and blank-only text is unchanged', () {
      expect(toNumberedList(''), '');
      expect(toBulletList('\n\n'), '\n\n');
    });
  });
}
