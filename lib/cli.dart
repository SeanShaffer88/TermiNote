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
import 'version.dart';

/// Command names recognised as CLI invocations.
const Set<String> cliCommands = <String>{
  'add',
  'list',
  'listify',
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
  'add-file',
  'stats',
  'version',
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

void _printNoteLine(Note note, void Function(String line) emit) {
  final tags = note.tags.isEmpty ? '' : '  [${note.tags.join(', ')}]';
  final pin = note.pinned ? '* ' : '';
  emit('${note.id}  $pin${note.title}$tags');
}

void _printNoteJson(Note note, void Function(String line) emit) =>
    emit(const JsonEncoder.withIndent('  ').convert(note.toJson()));

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
///
/// [dataDirOverride] and [out] are a test seam only: production passes
/// neither, so the data directory comes from the environment as usual
/// and normal output goes to stdout. When [out] is given it receives
/// every line of normal output instead (the help text arrives as one
/// multi-line call); errors keep going to stderr either way. An empty
/// [args] prints the help text and succeeds, like `help`.
Future<int> runCli(
  List<String> args, {
  String? dataDirOverride,
  void Function(String line)? out,
}) async {
  void emit(String line) {
    final sink = out;
    if (sink != null) {
      sink(line);
    } else {
      stdout.writeln(line);
    }
  }

  void printHelp() {
    final sink = out;
    if (sink != null) {
      sink(_helpText);
    } else {
      stdout.write(_helpText);
    }
  }

  if (args.isEmpty) {
    printHelp();
    return 0;
  }
  final command = args.first;
  final options = _parse(args.sublist(1));
  if (options == null) return 2;
  if (command == 'help') {
    printHelp();
    return 0;
  }

  final dataDir = dataDirOverride ?? StoreFile.resolveDataDir();
  final store = await StoreFile.load(dataDir);
  if (store.wasCorrupt) {
    stderr.writeln(
      'Note: the old notes file (notes.json) was damaged, so it was '
      'moved aside and a fresh notebook was started. The damaged file '
      'sits in the data folder with ".corrupt-" in its name.',
    );
  }
  final now = nowSeconds();

  Future<void> persist() => store.saveDirty();

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
      await persist();
      emit('Added note ${note.id} "${note.title}".');
      return 0;

    case 'list':
      final notes = store.list(
        search: options['search'] ?? '',
        tag: options['tag'],
        untagged: options.values.containsKey('untagged'),
        sort: sortModeFromName(options['sort']),
      );
      if (options.json) {
        emit(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(notes.map((n) => n.toJson()).toList()),
        );
      } else {
        for (final note in notes) {
          _printNoteLine(note, emit);
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
        emit(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(notes.map((n) => n.toJson()).toList()),
        );
      } else {
        for (final note in notes) {
          _printNoteLine(note, emit);
        }
      }
      return 0;

    case 'show':
      final id = _idArg(options, 'Usage: terminote show ID');
      if (id == null) return 2;
      final note = store.get(id) ?? store.getTrashed(id);
      if (note == null) return _notFound(id);
      if (options.json) {
        _printNoteJson(note, emit);
        return 0;
      }
      emit(note.title);
      if (note.tags.isNotEmpty) {
        emit('Tags: ${note.tags.join(', ')}');
      }
      emit('Created:  ${formatStamp(note.created)}');
      emit('Modified: ${formatStamp(note.modified)}');
      emit('');
      emit(note.body);
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
      await persist();
      emit('Updated note $id.');
      return 0;

    case 'delete':
      final id = _idArg(options, 'Usage: terminote delete ID');
      if (id == null) return 2;
      if (!store.delete(id)) return _notFound(id);
      await persist();
      emit('Moved note $id to the trash.');
      return 0;

    case 'restore':
      final id = _idArg(options, 'Usage: terminote restore ID');
      if (id == null) return 2;
      if (!store.restore(id)) {
        stderr.writeln('No note with id $id in the trash.');
        return 1;
      }
      await persist();
      emit('Restored note $id.');
      return 0;

    case 'delete-forever':
      final id = _idArg(options, 'Usage: terminote delete-forever ID');
      if (id == null) return 2;
      if (!store.deleteForever(id)) {
        stderr.writeln('No note with id $id in the trash.');
        return 1;
      }
      await persist();
      emit('Deleted note $id for good.');
      return 0;

    case 'empty-trash':
      store.emptyTrash();
      await persist();
      emit('Trash emptied.');
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
      await persist();
      emit('Moved $count note(s) to the trash.');
      return 0;

    case 'trash':
      if (options.json) {
        emit(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(store.trash.map((n) => n.toJson()).toList()),
        );
      } else {
        for (final note in store.trash) {
          _printNoteLine(note, emit);
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
      await persist();
      emit('Tagged note $id.');
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
      await persist();
      emit('Removed the tag from note $id.');
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
      await persist();
      emit('Renamed on $count note(s).');
      return 0;

    case 'tags':
      final entries = store.allTags();
      if (options.json) {
        emit(
          const JsonEncoder.withIndent(
            '  ',
          ).convert(<String, int>{for (final e in entries) e.key: e.value}),
        );
      } else {
        for (final entry in entries) {
          emit('${entry.key} (${entry.value})');
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
      await persist();
      emit('${command == 'pin' ? 'Pinned' : 'Unpinned'} note $id.');
      return 0;

    case 'duplicate':
      final id = _idArg(options, 'Usage: terminote duplicate ID');
      if (id == null) return 2;
      final copy = store.duplicate(id, now: now);
      if (copy == null) return _notFound(id);
      await persist();
      emit('Duplicated as note ${copy.id} "${copy.title}".');
      return 0;

    case 'listify':
      final id = _idArg(
        options,
        'Usage: terminote listify ID numbered|bullets|plain',
      );
      if (id == null) return 2;
      if (options.positional.length < 2) {
        stderr.writeln('Usage: terminote listify ID numbered|bullets|plain');
        return 2;
      }
      final note = store.get(id);
      if (note == null) return _notFound(id);
      final kind = options.positional[1];
      final converted = switch (kind) {
        'numbered' => toNumberedList(note.body),
        'bullets' => toBulletList(note.body),
        'plain' => stripListMarkers(note.body),
        _ => null,
      };
      if (converted == null) {
        stderr.writeln(
          'Unknown list style "$kind". Use numbered, bullets, or plain.',
        );
        return 2;
      }
      store.update(id, body: converted, now: now);
      await persist();
      emit(
        kind == 'plain'
            ? 'Note $id is now plain text.'
            : 'Note $id is now a $kind list.',
      );
      return 0;

    case 'export':
      if (options.positional.isEmpty) {
        stderr.writeln('Usage: terminote export FILE');
        return 2;
      }
      File(options.positional.first).writeAsStringSync(store.exportJson());
      emit(
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
        final result = store.importJson(file.readAsStringSync());
        await persist();
        if (result.skipped == 0) {
          emit('Imported ${result.imported} note(s).');
        } else {
          emit(
            'Imported ${result.imported} note(s); ${result.skipped} '
            'were already there and were skipped.',
          );
        }
        return 0;
      } on FormatException catch (e) {
        stderr.writeln('Could not import that file: ${e.message}');
        return 1;
      }

    case 'add-file':
      if (options.positional.isEmpty) {
        stderr.writeln('Usage: terminote add-file FILE');
        return 2;
      }
      final path = options.positional.first;
      final file = File(path);
      if (!file.existsSync()) {
        stderr.writeln('No such file: $path');
        return 1;
      }
      final name = path.split(RegExp(r'[/\\]')).last;
      final lower = name.toLowerCase();
      if (!lower.endsWith('.md') && !lower.endsWith('.txt')) {
        stderr.writeln('Only .md and .txt files can be added: $name');
        return 1;
      }
      if (file.lengthSync() > 5 * 1024 * 1024) {
        stderr.writeln('That file is too large to add (5 MB limit): $name');
        return 1;
      }
      final text = file.readAsStringSync();
      if (text.trim().isEmpty) {
        stderr.writeln('That file is empty: $name');
        return 1;
      }
      final note = store.importFileText(text, fileName: name, now: now);
      await persist();
      emit('Added note ${note.id} "${note.title}" from $name.');
      return 0;

    case 'version':
      emit('TermiNote $kAppVersion');
      return 0;

    case 'stats':
      final s = store.stats();
      if (options.json) {
        emit(
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
        emit('Notes: ${s.notes}');
        emit('In trash: ${s.trash}');
        emit('Tags: ${s.tags}');
        emit('Pinned: ${s.pinned}');
        emit('Total words: ${s.words}');
        emit('Total characters: ${s.characters}');
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
  listify ID numbered|bullets|plain       Make the note body a list, or
                                           plain text again
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
  add-file FILE                            Add one .md or .txt file as a
                                           note (the window does the same
                                           for dropped files)

Other
  stats [--json]                           Counts for the whole notebook
  version                                  Print the program version
  help                                     This text

Sort names: modifiedDesc, titleAsc, createdDesc, manual.
Exit codes: 0 fine, 1 not found / failed, 2 command line wrong.
''';
