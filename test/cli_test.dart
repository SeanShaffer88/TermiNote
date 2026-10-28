// Tests for the TermiNote command line (lib/cli.dart).
// Run with: flutter test
//
// Every test drives runCli through its test seam: a fresh temporary
// data directory per test (via dataDirOverride) and an output sink
// (via out), so each call behaves like a separate real invocation —
// the store is loaded from the note files on disk, the command runs,
// and whatever it saved is what the next call sees. Errors go to
// stderr and are not captured here; for error cases the exit code is
// the contract (0 fine, 1 not found / failed, 2 command line wrong).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/cli.dart';
import 'package:terminote/note_store.dart';
import 'package:terminote/version.dart';

void main() {
  late Directory dataDir;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('terminote_cli_test_');
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  /// Runs one CLI invocation against [dir] (this test's data dir by
  /// default) and returns its exit code and captured normal output.
  Future<({int code, String output})> cli(
    List<String> args, {
    Directory? dir,
  }) async {
    final chunks = <String>[];
    final code = await runCli(
      args,
      dataDirOverride: (dir ?? dataDir).path,
      out: chunks.add,
    );
    return (code: code, output: chunks.join('\n'));
  }

  /// The id out of an add command's "Added note N ..." line.
  int addedId(String output) {
    final match = RegExp(r'Added note (\d+)').firstMatch(output);
    expect(match, isNotNull, reason: 'add output was: $output');
    return int.parse(match!.group(1)!);
  }

  /// Names of the .md files in a data dir's notes (or trash) folder.
  List<String> mdNames(Directory dir, {bool trash = false}) {
    final folder = Directory(
      trash ? StoreFile.trashDirFor(dir.path) : StoreFile.notesDirFor(dir.path),
    );
    if (!folder.existsSync()) return <String>[];
    return folder
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.md'))
        .toList()
      ..sort();
  }

  group('help', () {
    test('help exits 0 and lists the commands', () async {
      final result = await cli(<String>['help']);
      expect(result.code, 0);
      for (final word in <String>[
        'add',
        'list',
        'show',
        'edit',
        'search',
        'delete',
        'delete-all',
        'listify',
        'export',
        'import',
        'stats',
        'Exit codes: 0 fine, 1 not found / failed, 2 command line wrong.',
      ]) {
        expect(result.output, contains(word));
      }
    });

    test('no arguments at all also prints the help text', () async {
      final result = await cli(<String>[]);
      expect(result.code, 0);
      expect(result.output, contains('TermiNote - a dark terminal-themed'));
      expect(result.output, contains('Usage: terminote <command>'));
    });
  });

  group('add, list, show', () {
    test('add prints the new id and writes a markdown file', () async {
      final result = await cli(<String>[
        'add',
        '--title',
        'Shopping list',
        '--body',
        'milk and eggs',
        '--tags',
        'home,errands',
      ]);
      expect(result.code, 0);
      final id = addedId(result.output);
      expect(result.output, contains('Added note $id "Shopping list".'));
      final files = mdNames(dataDir);
      expect(files, hasLength(1));
      expect(files.single, startsWith('$id-'));
      expect(files.single, contains('shopping-list'));
      final text = File(
        '${StoreFile.notesDirFor(dataDir.path)}'
        '${Platform.pathSeparator}${files.single}',
      ).readAsStringSync();
      expect(text, contains('milk and eggs'));
    });

    test('positional title works too', () async {
      final result = await cli(<String>['add', 'Loose thought']);
      expect(result.code, 0);
      expect(result.output, contains('"Loose thought"'));
    });

    test('list shows id, title and tags, and never body text', () async {
      final added = await cli(<String>[
        'add',
        '--title',
        'Shopping list',
        '--body',
        'zebra-secret-body-word',
        '--tags',
        'home',
      ]);
      final id = addedId(added.output);
      final result = await cli(<String>['list']);
      expect(result.code, 0);
      expect(result.output, contains('$id'));
      expect(result.output, contains('Shopping list'));
      expect(result.output, contains('[home]'));
      expect(result.output, isNot(contains('zebra-secret-body-word')));
    });

    test('show prints the title and the full body', () async {
      final added = await cli(<String>[
        'add',
        '--title',
        'Ideas',
        '--body',
        'first line\nsecond line with zebra',
        '--tags',
        'work',
      ]);
      final id = addedId(added.output);
      final result = await cli(<String>['show', '$id']);
      expect(result.code, 0);
      expect(result.output, contains('Ideas'));
      expect(result.output, contains('Tags: work'));
      expect(result.output, contains('first line'));
      expect(result.output, contains('second line with zebra'));
    });
  });

  group('edit', () {
    test('edit --title renames the note and its file', () async {
      final added = await cli(<String>['add', 'Weekly shop']);
      final id = addedId(added.output);
      final before = mdNames(dataDir);
      expect(before.single, contains('weekly-shop'));

      final result = await cli(<String>[
        'edit',
        '$id',
        '--title',
        'Renamed note',
      ]);
      expect(result.code, 0);
      expect(result.output, contains('Updated note $id.'));

      final after = mdNames(dataDir);
      expect(after, hasLength(1));
      expect(after.single, contains('renamed-note'));
      expect(after.single, isNot(before.single));

      final list = await cli(<String>['list']);
      expect(list.output, contains('Renamed note'));
      expect(list.output, isNot(contains('Weekly shop')));
    });
  });

  group('pin', () {
    test('pin marks the list line, unpin clears it', () async {
      final added = await cli(<String>['add', 'Pinned idea']);
      final id = addedId(added.output);

      final pinned = await cli(<String>['pin', '$id']);
      expect(pinned.code, 0);
      expect(pinned.output, contains('Pinned note $id.'));
      var list = await cli(<String>['list']);
      expect(list.output, contains('* Pinned idea'));

      final unpinned = await cli(<String>['unpin', '$id']);
      expect(unpinned.code, 0);
      expect(unpinned.output, contains('Unpinned note $id.'));
      list = await cli(<String>['list']);
      expect(list.output, contains('Pinned idea'));
      expect(list.output, isNot(contains('* Pinned idea')));
    });
  });

  group('search and filters', () {
    test('search finds a note by a word in its body', () async {
      await cli(<String>['add', 'Plain note', '--body', 'nothing special']);
      final hit = await cli(<String>[
        'add',
        'Field notes',
        '--body',
        'a zebra at dawn',
      ]);
      final hitId = addedId(hit.output);
      final result = await cli(<String>['search', 'zebra']);
      expect(result.code, 0);
      expect(result.output, contains('Field notes'));
      expect(result.output, contains('$hitId'));
      expect(result.output, isNot(contains('Plain note')));
      // Search results are still titles-only lines.
      expect(result.output, isNot(contains('a zebra at dawn')));
    });

    test('list --tag keeps only notes with that tag', () async {
      await cli(<String>['add', 'Work note', '--tags', 'work']);
      await cli(<String>['add', 'Home note', '--tags', 'home']);
      final result = await cli(<String>['list', '--tag', 'work']);
      expect(result.code, 0);
      expect(result.output, contains('Work note'));
      expect(result.output, isNot(contains('Home note')));
    });
  });

  group('listify', () {
    test('numbered then plain, seen through show both ways', () async {
      final added = await cli(<String>[
        'add',
        'Steps',
        '--body',
        'wake up\nmake tea',
      ]);
      final id = addedId(added.output);

      final numbered = await cli(<String>['listify', '$id', 'numbered']);
      expect(numbered.code, 0);
      expect(numbered.output, contains('Note $id is now a numbered list.'));
      var shown = await cli(<String>['show', '$id']);
      expect(shown.output, contains('1. wake up'));
      expect(shown.output, contains('2. make tea'));

      final plain = await cli(<String>['listify', '$id', 'plain']);
      expect(plain.code, 0);
      expect(plain.output, contains('Note $id is now plain text.'));
      shown = await cli(<String>['show', '$id']);
      expect(shown.output, contains('wake up\nmake tea'));
      expect(shown.output, isNot(contains('1. wake up')));
    });
  });

  group('trash round trip', () {
    test('delete hides, trash lists, restore returns, '
        'delete-forever removes the file', () async {
      final added = await cli(<String>['add', 'Doomed note']);
      final id = addedId(added.output);
      expect(mdNames(dataDir), hasLength(1));

      final deleted = await cli(<String>['delete', '$id']);
      expect(deleted.code, 0);
      expect(deleted.output, contains('Moved note $id to the trash.'));
      var list = await cli(<String>['list']);
      expect(list.output, isNot(contains('Doomed note')));
      expect(mdNames(dataDir), isEmpty);
      expect(mdNames(dataDir, trash: true), hasLength(1));

      final trash = await cli(<String>['trash']);
      expect(trash.code, 0);
      expect(trash.output, contains('Doomed note'));

      final restored = await cli(<String>['restore', '$id']);
      expect(restored.code, 0);
      expect(restored.output, contains('Restored note $id.'));
      list = await cli(<String>['list']);
      expect(list.output, contains('Doomed note'));
      expect(mdNames(dataDir), hasLength(1));
      expect(mdNames(dataDir, trash: true), isEmpty);

      await cli(<String>['delete', '$id']);
      final purged = await cli(<String>['delete-forever', '$id']);
      expect(purged.code, 0);
      expect(purged.output, contains('Deleted note $id for good.'));
      expect(mdNames(dataDir, trash: true), isEmpty);
      final trashAfter = await cli(<String>['trash']);
      expect(trashAfter.output, isNot(contains('Doomed note')));
    });

    test(
      'delete-all needs --yes, empties the list, trash keeps files',
      () async {
        await cli(<String>['add', 'One']);
        await cli(<String>['add', 'Two']);

        final refused = await cli(<String>['delete-all']);
        expect(refused.code, 2);
        var list = await cli(<String>['list']);
        expect(list.output, contains('One'));
        expect(list.output, contains('Two'));

        final result = await cli(<String>['delete-all', '--yes']);
        expect(result.code, 0);
        expect(result.output, contains('Moved 2 note(s) to the trash.'));
        list = await cli(<String>['list']);
        expect(list.output, isNot(contains('One')));
        expect(list.output, isNot(contains('Two')));
        expect(mdNames(dataDir), isEmpty);
        expect(mdNames(dataDir, trash: true), hasLength(2));
        final trash = await cli(<String>['trash']);
        expect(trash.output, contains('One'));
        expect(trash.output, contains('Two'));
      },
    );
  });

  group('export and import', () {
    test('export then import into a second dir; re-import skips all', () async {
      await cli(<String>['add', 'First', '--body', 'alpha body']);
      await cli(<String>['add', 'Second', '--body', 'beta body']);
      final exportPath = '${dataDir.path}${Platform.pathSeparator}export.json';
      final exported = await cli(<String>['export', exportPath]);
      expect(exported.code, 0);
      expect(exported.output, contains('Exported 2 note(s)'));
      expect(File(exportPath).existsSync(), isTrue);

      final other = Directory.systemTemp.createTempSync(
        'terminote_cli_test_other_',
      );
      addTearDown(() {
        if (other.existsSync()) other.deleteSync(recursive: true);
      });

      final imported = await cli(<String>['import', exportPath], dir: other);
      expect(imported.code, 0);
      expect(imported.output, contains('Imported 2 note(s).'));
      final otherList = await cli(<String>['list'], dir: other);
      expect(otherList.output, contains('First'));
      expect(otherList.output, contains('Second'));
      expect(mdNames(other), hasLength(2));

      final again = await cli(<String>['import', exportPath], dir: other);
      expect(again.code, 0);
      expect(
        again.output,
        contains('Imported 0 note(s); 2 were already there and were skipped.'),
      );
      expect(mdNames(other), hasLength(2));
    });
  });

  group('errors and edge cases', () {
    test('show with a missing id exits 1', () async {
      final result = await cli(<String>['show', '999']);
      expect(result.code, 1);
    });

    test('show with a malformed id exits 2', () async {
      final result = await cli(<String>['show', 'abc']);
      expect(result.code, 2);
    });

    test('add with no title at all exits 2', () async {
      final result = await cli(<String>['add']);
      expect(result.code, 2);
      expect(mdNames(dataDir), isEmpty);
    });

    test('an unknown command exits 2', () async {
      final result = await cli(<String>['frobnicate']);
      expect(result.code, 2);
    });

    test('a blank title becomes Untitled note (the store rule the '
        'window follows too)', () async {
      final result = await cli(<String>['add', '--title', '']);
      expect(result.code, 0);
      expect(result.output, contains('"Untitled note"'));
      final list = await cli(<String>['list']);
      expect(list.output, contains('Untitled note'));
    });

    test('stats reports the counts', () async {
      await cli(<String>['add', 'Counted', '--body', 'three small words']);
      final result = await cli(<String>['stats']);
      expect(result.code, 0);
      expect(result.output, contains('Notes: 1'));
      expect(result.output, contains('In trash: 0'));
    });

    test('version prints the program version', () async {
      expect(isCliArgs(<String>['version']), isTrue);
      final result = await cli(<String>['version']);
      expect(result.code, 0);
      expect(result.output, contains('TermiNote $kAppVersion'));
    });
  });
}
