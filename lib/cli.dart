/// TermiNote command line: every operation the window offers, from a
/// terminal. `main()` calls [isCliArgs] and then [runCli] when the first
/// argument is a command name; otherwise the GUI starts.
///
/// Exit codes: 0 success, 1 the thing asked for was not found or the
/// operation failed, 2 the command line itself was wrong.
///
/// List-style output prints id + title + tags only. Body text is printed
/// only by `show`, which is the one command that exists to print it.
library;

import 'dart:convert';
import 'dart:io';

import 'note_store.dart';

/// Command names recognised as CLI invocations.
const Set<String> cliCommands = <String>{
  'add',
  'list',
  'show',
  'edit',
  'search',
  'delete',
  'restore',
  'delete-forever',
  'empty-trash',
  'delete-all',
  'trash',
  'tag',
  'untag',
  'rename-tag',
  'tags',
  'pin',
  'unpin',
  'duplicate',
  'export',
  'import',
  'stats',
  'help',
};

/// True when [args] should be handled by the CLI rather than the GUI.
bool isCliArgs(List<String> args) =>
    args.isNotEmpty && cliCommands.contains(args.first);

/// Formats unix seconds the way the phone app does, e.g.
/// `2022-11-30 (Wed) 01:23:51 AM`. All values are local time.
String formatStamp(int seconds) {
  final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  const days = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String two(int v) => v.toString().padLeft(2, '0');
  var hour = d.hour % 12;
  if (hour == 0) hour = 12;
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '(${days[d.weekday - 1]}) ${two(hour)}:${two(d.minute)}:'
      '${two(d.second)} $ampm';
}

class _Options {
  final List<String> positional = <String>[];
  final Map<String, String> values = <String, String>{};
  bool json = false;
  bool yes = false;

  String? operator [](String key) => values[key];
}

/// Splits raw arguments into positionals, `--key value` / `--key=value`
/// options, and the `--json` / `--yes` flags. Returns null (after printing
/// the problem) when an option is malformed.
_Options? _parse(List<String> args) {
  final options = _Options();
  var i = 0;
  while (i < args.length) {
    final arg = args[i];
    if (arg == '--json') {
      options.json = true;
    } else if (arg == '--yes') {
      options.yes = true;
    } else if (arg == '--untagged') {
      options.values['untagged'] = 'true';
    } else if (arg.startsWith('--')) {
      final body = arg.substring(2);
      final eq = body.indexOf('=');
      if (eq >= 0) {
        options.values[body.substring(0, eq)] = body.substring(eq + 1);
      } else {
        if (i + 1 >= args.length) {
          stderr.writeln('Option --$body needs a value.');
          return null;
        }
        options.values[body] = args[i + 1];
        i++;
      }
    } else {
      options.positional.add(arg);
    }
    i++;
  }
  return options;
}

void _printNoteLine(Note note) {
  final tags = note.tags.isEmpty ? '' : '  [${note.tags.join(', ')}]';
  final pin = note.pinned ? '* ' : '';
  stdout.writeln('${note.id}  $pin${note.title}$tags');
}

void _printNoteJson(Note note) =>
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(note.toJson()));

int _notFound(int id) {
  stderr.writeln('No note with id $id.');
  return 1;
}

int? _idArg(_Options options, String usage) {
  if (options.positional.isEmpty) {
    stderr.writeln(usage);
    return null;
  }
  final id = int.tryParse(options.positional.first);
  if (id == null) {
    stderr.writeln('"${options.positional.first}" is not a note id.');
    return null;
  }
  return id;
}

/// Runs one CLI invocation and returns its exit code.
Future<int> runCli(List<String> args) async {
  final command = args.first;
  final options = _parse(args.sublist(1));
  if (options == null) return 2;
  if (command == 'help') {
    stdout.write(_helpText);
    return 0;
  }

  final path = StoreFile.resolvePath();
  final store = StoreFile.load(path);
  if (store.wasCorrupt) {
    stderr.writeln(
      'Note: the data file was damaged, so it was moved aside and a fresh '
      'notebook was started. The damaged file sits next to the data file '
      'with ".corrupt-" in its name.',
    );
  }
  final now = nowSeconds();

  void persist() => StoreFile.save(path, store);

  switch (command) {
    case 'add':
      if (options.positional.isEmpty && options['title'] == null) {
        stderr.writeln(
          'Usage: terminote add "title" [--body TEXT] '
          '[--tags a,b]',
        );
        return 2;
      }
      final note = store.add(
        title: options['title'] ?? options.positional.join(' '),
        body: options['body'] ?? '',
        tags: parseTags(options['tags'] ?? ''),
        now: now,
      );
      persist();
      stdout.writeln('Added note ${note.id} "${note.title}".');
      return 0;

    case 'list':
      final notes = store.list(
        search: options['search'] ?? '',
        tag: options['tag'],
        untagged: options.values.containsKey('untagged'),
        sort: sortModeFromName(options['sort']),
      );
      if (options.json) {
        stdout.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(notes.map((n) => n.toJson()).toList()),
        );
      } else {
        for (final note in notes) {
          _printNoteLine(note);
        }
      }
      return 0;

    case 'search':
      final query = options.positional.join(' ');
      if (query.isEmpty) {
        stderr.writeln('Usage: terminote search WORDS');
        return 2;
      }
      final notes = store.list(search: query);
      if (options.json) {
        stdout.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(notes.map((n) => n.toJson()).toList()),
        );
      } else {
        for (final note in notes) {
          _printNoteLine(note);
        }
      }
      return 0;

    case 'show':
      final id = _idArg(options, 'Usage: terminote show ID');
      if (id == null) return 2;
      final note = store.get(id) ?? store.getTrashed(id);
      if (note == null) return _notFound(id);
      if (options.json) {
        _printNoteJson(note);
        return 0;
      }
      stdout.writeln(note.title);
      if (note.tags.isNotEmpty) {
        stdout.writeln('Tags: ${note.tags.join(', ')}');
      }
      stdout.writeln('Created:  ${formatStamp(note.created)}');
      stdout.writeln('Modified: ${formatStamp(note.modified)}');
      stdout.writeln('');
      stdout.writeln(note.body);
      return 0;

    case 'edit':
      final id = _idArg(
        options,
        'Usage: terminote edit ID [--title T] '
        '[--body B] [--tags a,b]',
      );
      if (id == null) return 2;
      if (store.get(id) == null) return _notFound(id);
      store.update(
        id,
        title: options['title'],
        body: options['body'],
        tags: options['tags'] == null ? null : parseTags(options['tags']!),
        now: now,
      );
      persist();
      stdout.writeln('Updated note $id.');
      return 0;

    case 'delete':
      final id = _idArg(options, 'Usage: terminote delete ID');
      if (id == null) return 2;
      if (!store.delete(id)) return _notFound(id);
      persist();
      stdout.writeln('Moved note $id to the trash.');
      return 0;

    case 'restore':
      final id = _idArg(options, 'Usage: terminote restore ID');
      if (id == null) return 2;
      if (!store.restore(id)) {
        stderr.writeln('No note with id $id in the trash.');
        return 1;
      }
      persist();
      stdout.writeln('Restored note $id.');
      return 0;

    case 'delete-forever':
      final id = _idArg(options, 'Usage: terminote delete-forever ID');
      if (id == null) return 2;
      if (!store.deleteForever(id)) {
        stderr.writeln('No note with id $id in the trash.');
        return 1;
      }
      persist();
      stdout.writeln('Deleted note $id for good.');
      return 0;

    case 'empty-trash':
      store.emptyTrash();
      persist();
      stdout.writeln('Trash emptied.');
      return 0;

    case 'delete-all':
      if (!options.yes) {
        stderr.writeln(
          'This moves every note to the trash. '
          'Run it again with --yes if you mean it.',
        );
        return 2;
      }
      final count = store.deleteAll();
      persist();
      stdout.writeln('Moved $count note(s) to the trash.');
      return 0;

    case 'trash':
      if (options.json) {
        stdout.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(store.trash.map((n) => n.toJson()).toList()),
        );
      } else {
        for (final note in store.trash) {
          _printNoteLine(note);
        }
      }
      return 0;

    case 'tag':
      final id = _idArg(options, 'Usage: terminote tag ID TAG');
      if (id == null) return 2;
      if (options.positional.length < 2) {
        stderr.writeln('Usage: terminote tag ID TAG');
        return 2;
      }
      if (store.get(id) == null) return _notFound(id);
      if (!store.addTag(id, options.positional[1], now: now)) {
        stderr.writeln('That tag is empty after cleaning it up.');
        return 1;
      }
      persist();
      stdout.writeln('Tagged note $id.');
      return 0;

    case 'untag':
      final id = _idArg(options, 'Usage: terminote untag ID TAG');
      if (id == null) return 2;
      if (options.positional.length < 2) {
        stderr.writeln('Usage: terminote untag ID TAG');
        return 2;
      }
      if (!store.removeTag(id, options.positional[1], now: now)) {
        stderr.writeln('Note $id does not have that tag (or does not exist).');
        return 1;
      }
      persist();
      stdout.writeln('Removed the tag from note $id.');
      return 0;

    case 'rename-tag':
      if (options.positional.length < 2) {
        stderr.writeln('Usage: terminote rename-tag OLD NEW');
        return 2;
      }
      final count = store.renameTag(
        options.positional[0],
        options.positional[1],
        now: now,
      );
      persist();
      stdout.writeln('Renamed on $count note(s).');
      return 0;

    case 'tags':
      final entries = store.allTags();
      if (options.json) {
        stdout.writeln(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(<String, int>{for (final e in entries) e.key: e.value}),
        );
      } else {
        for (final entry in entries) {
          stdout.writeln('${entry.key} (${entry.value})');
        }
      }
      return 0;

    case 'pin':
    case 'unpin':
      final id = _idArg(options, 'Usage: terminote $command ID');
      if (id == null) return 2;
      if (!store.setPinned(id, pinned: command == 'pin', now: now)) {
        return _notFound(id);
      }
      persist();
      stdout.writeln('${command == 'pin' ? 'Pinned' : 'Unpinned'} note $id.');
      return 0;

    case 'duplicate':
      final id = _idArg(options, 'Usage: terminote duplicate ID');
      if (id == null) return 2;
      final copy = store.duplicate(id, now: now);
      if (copy == null) return _notFound(id);
      persist();
      stdout.writeln('Duplicated as note ${copy.id} "${copy.title}".');
      return 0;

    case 'export':
      if (options.positional.isEmpty) {
        stderr.writeln('Usage: terminote export FILE');
        return 2;
      }
      File(options.positional.first).writeAsStringSync(store.exportJson());
      stdout.writeln(
        'Exported ${store.notes.length} note(s) to '
        '${options.positional.first}.',
      );
      return 0;

    case 'import':
      if (options.positional.isEmpty) {
        stderr.writeln('Usage: terminote import FILE');
        return 2;
      }
      final file = File(options.positional.first);
      if (!file.existsSync()) {
        stderr.writeln('No such file: ${options.positional.first}');
        return 1;
      }
      try {
        final count = store.importJson(file.readAsStringSync());
        persist();
        stdout.writeln('Imported $count note(s).');
        return 0;
      } on FormatException catch (e) {
        stderr.writeln('Could not import that file: ${e.message}');
        return 1;
      }

    case 'stats':
      final s = store.stats();
      if (options.json) {
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(<String, int>{
            'notes': s.notes,
            'trash': s.trash,
            'tags': s.tags,
            'pinned': s.pinned,
            'words': s.words,
            'characters': s.characters,
          }),
        );
      } else {
        stdout.writeln('Notes: ${s.notes}');
        stdout.writeln('In trash: ${s.trash}');
        stdout.writeln('Tags: ${s.tags}');
        stdout.writeln('Pinned: ${s.pinned}');
        stdout.writeln('Total words: ${s.words}');
        stdout.writeln('Total characters: ${s.characters}');
      }
      return 0;
  }
  stderr.writeln('Unknown command "$command". Run: terminote help');
  return 2;
}

const String _helpText = '''
TermiNote - a dark terminal-themed notepad.

Usage: terminote <command> [options]
With no command, the TermiNote window opens.

Notes
  add "title" [--body TEXT] [--tags a,b]   Add a note
  list [--tag TAG] [--untagged] [--search TEXT] [--sort NAME] [--json]
                                           List notes (titles only)
  show ID [--json]                         Print one note in full
  edit ID [--title T] [--body B] [--tags a,b]
  search WORDS [--json]                    Find notes (titles only)
  delete ID                                Move a note to the trash
  duplicate ID                             Copy a note
  pin ID / unpin ID                        Pin or unpin a note

Tags
  tag ID TAG                               Add a tag to a note
  untag ID TAG                             Remove a tag from a note
  rename-tag OLD NEW                       Rename a tag everywhere
  tags [--json]                            List tags with counts

Trash
  trash [--json]                           List the trash (titles only)
  restore ID                               Bring a note back from the trash
  delete-forever ID                        Delete a trashed note for good
  empty-trash                              Empty the trash
  delete-all --yes                         Move every note to the trash

Files
  export FILE                              Write all notes to a JSON file
  import FILE                              Merge notes from a JSON file

Other
  stats [--json]                           Counts for the whole notebook
  help                                     This text

Sort names: modifiedDesc, titleAsc, createdDesc, manual.
Exit codes: 0 fine, 1 not found / failed, 2 command line wrong.
''';
