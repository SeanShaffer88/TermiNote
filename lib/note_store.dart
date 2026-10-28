/// TermiNote data layer: the note model, the store, every note operation,
/// and reading/writing the notes on disk.
///
/// This file has no Flutter imports on purpose, so the whole thing is plain
/// Dart and fully testable. The GUI and the CLI both work through these
/// operations; there are no GUI-only capabilities.
///
/// On-disk format (since 0.3.0): one Markdown file per note inside a
/// `notes` folder in the data directory, with trashed notes in a `trash`
/// subfolder. Each file is named `<id>-<slug>.md` and holds a small
/// front-matter block (id, title, tags, pinned, created, modified, order)
/// followed by the body as plain Markdown text:
///
/// ```markdown
/// ---
/// id: 3
/// title: Non-Negotiable
/// tags: [rules, home]
/// pinned: true
/// created: 1761674007
/// modified: 1761674325
/// order: 0
/// ---
///
/// <body exactly as typed>
/// ```
///
/// Times are unix seconds. `order` is the note's place in the manual
/// drag order.
///
/// The JSON shape below is kept as the export/import interchange format,
/// and as the reader for the pre-0.3.0 single-file store: when a
/// `notes.json` from an older version is found and no Markdown notes
/// exist yet, it is converted automatically (see [StoreFile.load]).
///
/// ```json
/// {"next_id": 3,
///  "notes": [{"id": 1, "title": "...", "body": "...", "tags": ["a"],
///             "pinned": false, "created": 1700000000,
///             "modified": 1700000000}],
///  "trash": [],
///  "order": [2, 1]}
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// How the note list is sorted.
enum SortMode {
  /// Newest modified first (the default).
  modifiedDesc,

  /// Title A to Z.
  titleAsc,

  /// Newest created first.
  createdDesc,

  /// The manual order set by dragging cards (the store's `order` list).
  manual,
}

/// Parses a sort mode name; unknown names fall back to [SortMode.modifiedDesc].
SortMode sortModeFromName(String? name) {
  for (final mode in SortMode.values) {
    if (mode.name == name) return mode;
  }
  return SortMode.modifiedDesc;
}

/// Current time in unix seconds.
int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Normalises one tag: trims, lowercases, caps it at 40 characters.
/// Returns an empty string for a tag that should be dropped.
String normalizeTag(String raw) {
  var tag = raw.trim().toLowerCase();
  if (tag.length > 40) tag = tag.substring(0, 40).trim();
  return tag;
}

/// Normalises a collection of tags: each tag cleaned by [normalizeTag],
/// empties dropped, duplicates removed, first-seen order kept.
List<String> normalizeTags(Iterable<String> raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final item in raw) {
    final tag = normalizeTag(item);
    if (tag.isEmpty || !seen.add(tag)) continue;
    result.add(tag);
  }
  return result;
}

/// Parses a comma-separated tag string (as typed in the editor or CLI).
List<String> parseTags(String text) => normalizeTags(text.split(','));

/// A number list marker at the start of a line: "1. " or "12) ",
/// including a marker with nothing after it (an empty list item, "3.").
final RegExp _numberMarker = RegExp(r'^\s*\d+[.)](?:\s+|$)');

/// A bullet list marker at the start of a line: "• ", including a marker
/// with nothing after it.
final RegExp _bulletMarker = RegExp(r'^\s*•(?:\s+|$)');

/// Any recognised list marker: a bullet ("• ", "- ", "* ") or a number
/// ("1. ", "12) "). The marker must be followed by a space or the end of
/// the line, so plain text like "1.5 litres" or "-5 degrees" is never
/// mistaken for a list item.
final RegExp _anyListMarker = RegExp(r'^\s*(?:•|-|\*|\d+[.)])(?:\s+|$)');

/// Splits note text into lines, normalising Windows (CRLF) and old
/// Mac (CR) line endings to the plain newline the app writes itself —
/// so text that arrived from a hand-edited file converts cleanly.
List<String> _linesOf(String text) =>
    text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

/// Removes any list marker (number, "• ", "- ", "* ") from the start of
/// every line. Lines without a marker are returned exactly as they are,
/// blank lines included.
String stripListMarkers(String text) {
  return _linesOf(
    text,
  ).map((line) => line.replaceFirst(_anyListMarker, '')).join('\n');
}

/// Turns plain text into a numbered list: existing list markers are
/// stripped first, then every non-empty line is prefixed "1. ", "2. ",
/// "3. " … in order. Blank lines stay blank and do not use up a number;
/// a line that holds only a marker (an empty list item) keeps its place
/// in the numbering as a bare "3.".
///
/// Toggle: when every non-empty line already carries a number marker,
/// the markers are stripped instead and the plain text is returned —
/// so calling this twice converts a list back to plain text. The GUI
/// and the CLI share this behaviour because it lives here.
String toNumberedList(String text) {
  final lines = _linesOf(text);
  final nonEmpty = lines.where((line) => line.trim().isNotEmpty);
  if (nonEmpty.isNotEmpty &&
      nonEmpty.every((line) => _numberMarker.hasMatch(line))) {
    return stripListMarkers(text);
  }
  var next = 0;
  final out = <String>[];
  for (final line in lines) {
    final stripped = line.replaceFirst(_anyListMarker, '');
    if (stripped.trim().isNotEmpty) {
      next++;
      out.add('$next. $stripped');
    } else if (_anyListMarker.hasMatch(line)) {
      // An empty list item: it keeps a number of its own.
      next++;
      out.add('$next.');
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}

/// Turns plain text into a bullet list: existing list markers are
/// stripped first, then every non-empty line is prefixed "• ". Blank
/// lines stay blank; a line that holds only a marker (an empty list
/// item) becomes a bare "•".
///
/// Toggle: when every non-empty line already carries a "•" marker, the
/// markers are stripped instead and the plain text is returned — so
/// calling this twice converts a list back to plain text. The GUI and
/// the CLI share this behaviour because it lives here.
String toBulletList(String text) {
  final lines = _linesOf(text);
  final nonEmpty = lines.where((line) => line.trim().isNotEmpty);
  if (nonEmpty.isNotEmpty &&
      nonEmpty.every((line) => _bulletMarker.hasMatch(line))) {
    return stripListMarkers(text);
  }
  final out = <String>[];
  for (final line in lines) {
    final stripped = line.replaceFirst(_anyListMarker, '');
    if (stripped.trim().isNotEmpty) {
      out.add('• $stripped');
    } else if (_anyListMarker.hasMatch(line)) {
      out.add('•');
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}

/// Builds the file-name slug for a note title: lowercased, every run of
/// non-alphanumeric characters replaced by a single dash, dashes trimmed
/// from the ends, capped at 40 characters. An empty result (a title with
/// no letters or digits at all) falls back to `note`.
String noteSlug(String title) {
  var slug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  slug = slug.replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 40) {
    slug = slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  }
  return slug.isEmpty ? 'note' : slug;
}

/// The on-disk file name for a note: `<id>-<slug>.md`. The id prefix
/// keeps names unique and stable even when two notes share a title.
String noteFileName(Note note) => '${note.id}-${noteSlug(note.title)}.md';

/// Serialises a note to its Markdown file text: the front-matter block,
/// a blank line, then the body exactly as typed.
///
/// The title is written on one line, so any line breaks inside it are
/// flattened to spaces in the file (titles are single-line everywhere in
/// the program). Tags are written without brackets or commas inside
/// them — the tag rules already keep commas out, this just keeps a
/// hand-edited tag from breaking the file's own header.
String encodeNoteFile(Note note) {
  final safeTitle = note.title.replaceAll(RegExp(r'[\r\n]+'), ' ');
  final safeTags = note.tags
      .map((t) => t.replaceAll(RegExp(r'[\[\],]'), ''))
      .join(', ');
  final buffer = StringBuffer()
    ..writeln('---')
    ..writeln('id: ${note.id}')
    ..writeln('title: $safeTitle')
    ..writeln('tags: [$safeTags]')
    ..writeln('pinned: ${note.pinned}')
    ..writeln('created: ${note.created}')
    ..writeln('modified: ${note.modified}')
    ..writeln('order: ${note.order}')
    ..writeln('---')
    ..writeln()
    ..write(note.body);
  return buffer.toString();
}

/// Reads a note back from its Markdown file text. Tolerant by design —
/// a note's text must never be lost because its header is odd:
///
/// - No front matter (or a front-matter block with nothing recognisable
///   in it): the whole file is the body, and the title is the first
///   non-empty line, or one derived from [fileName].
/// - Missing fields default sensibly: the id comes from the file name's
///   numeric prefix when there is one (otherwise 0, and the loader
///   hands out a fresh id), times come from [fileModifiedSeconds].
/// - Unknown front-matter keys are ignored.
///
/// [fileName] is the file's base name (used for the id prefix and the
/// title fallback, and remembered on the note so later saves can find
/// and replace the same file).
Note decodeNoteFile(
  String text, {
  required String fileName,
  int fileModifiedSeconds = 0,
}) {
  Note fallback() {
    var title = '';
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) {
        title = trimmed;
        break;
      }
    }
    if (title.isEmpty) title = _titleFromFileName(fileName);
    return Note(
      id: _idFromFileName(fileName),
      title: title,
      body: text,
      tags: <String>[],
      pinned: false,
      created: fileModifiedSeconds,
      modified: fileModifiedSeconds,
    )..fileName = fileName;
  }

  final lines = text.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') return fallback();
  var close = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      close = i;
      break;
    }
  }
  if (close < 0) return fallback();

  int? id;
  String? title;
  List<String>? tags;
  bool? pinned;
  int? created;
  int? modified;
  int? order;
  var recognised = 0;
  final fieldPattern = RegExp(r'^([A-Za-z_]+):(.*)$');
  for (var i = 1; i < close; i++) {
    final match = fieldPattern.firstMatch(lines[i].trimRight());
    if (match == null) continue;
    var value = match.group(2)!;
    if (value.startsWith(' ')) value = value.substring(1);
    value = value.trimRight();
    switch (match.group(1)) {
      case 'id':
        id = int.tryParse(value);
        if (id != null) recognised++;
      case 'title':
        title = value;
        recognised++;
      case 'tags':
        var inner = value.trim();
        if (inner.startsWith('[') && inner.endsWith(']')) {
          inner = inner.substring(1, inner.length - 1);
        }
        tags = inner.trim().isEmpty
            ? <String>[]
            : normalizeTags(inner.split(',').map((t) => t.trim()));
        recognised++;
      case 'pinned':
        pinned = value == 'true';
        recognised++;
      case 'created':
        created = int.tryParse(value);
        if (created != null) recognised++;
      case 'modified':
        modified = int.tryParse(value);
        if (modified != null) recognised++;
      case 'order':
        order = int.tryParse(value);
        if (order != null) recognised++;
    }
  }
  if (recognised == 0) return fallback();

  // The body is everything after the closing fence, with the one blank
  // separator line the writer leaves dropped if it is there.
  var bodyLines = lines.sublist(close + 1);
  if (bodyLines.isNotEmpty && bodyLines.first.trim().isEmpty) {
    bodyLines = bodyLines.sublist(1);
  }
  final parsedId = id ?? _idFromFileName(fileName);
  return Note(
    id: parsedId,
    title: title ?? _titleFromFileName(fileName),
    body: bodyLines.join('\n'),
    tags: tags ?? <String>[],
    pinned: pinned ?? false,
    created: created ?? fileModifiedSeconds,
    modified: modified ?? fileModifiedSeconds,
    order: order ?? 0,
  )..fileName = fileName;
}

/// The numeric id prefix of a note file name (`3-non-negotiable.md`
/// gives 3). Returns 0 when the name has no numeric prefix.
int _idFromFileName(String fileName) {
  final dash = fileName.indexOf('-');
  if (dash <= 0) return 0;
  return int.tryParse(fileName.substring(0, dash)) ?? 0;
}

/// A readable title from a note file name: extension and id prefix
/// dropped, dashes turned back into spaces. Falls back to the store's
/// usual placeholder when nothing readable remains.
String _titleFromFileName(String fileName) {
  var base = fileName;
  if (base.toLowerCase().endsWith('.md')) {
    base = base.substring(0, base.length - 3);
  }
  final dash = base.indexOf('-');
  if (dash > 0 && int.tryParse(base.substring(0, dash)) != null) {
    base = base.substring(dash + 1);
  }
  final title = base.replaceAll('-', ' ').trim();
  return title.isEmpty ? 'Untitled note' : title;
}

/// One note: a title and a body, plus tags, a pin flag, and timestamps.
class Note {
  Note({
    required this.id,
    required this.title,
    required this.body,
    required this.tags,
    required this.pinned,
    required this.created,
    required this.modified,
    this.order = 0,
  });

  /// Tolerantly reads a note from decoded JSON; returns null when the value
  /// is not an object with a usable id. Unknown fields are ignored.
  static Note? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    if (id is! num) return null;
    final rawTags = value['tags'];
    return Note(
      id: id.toInt(),
      title: value['title']?.toString() ?? '',
      body: value['body']?.toString() ?? '',
      tags: rawTags is List
          ? normalizeTags(rawTags.map((t) => t.toString()))
          : <String>[],
      pinned: value['pinned'] == true,
      created: value['created'] is num ? (value['created'] as num).toInt() : 0,
      modified: value['modified'] is num
          ? (value['modified'] as num).toInt()
          : 0,
      order: value['order'] is num ? (value['order'] as num).toInt() : 0,
    );
  }

  /// The note's unique id; never reused.
  int id;

  /// The title. This is the only note text the main list ever shows.
  String title;

  /// The body text. Only ever shown inside the editor.
  String body;

  /// Normalised tags (lowercase, de-duplicated).
  List<String> tags;

  /// Pinned notes float to the top of the list.
  bool pinned;

  /// Creation time, unix seconds.
  int created;

  /// Last change time, unix seconds.
  int modified;

  /// This note's place in the manual drag order (mirrors its position
  /// in [NoteStore.order]). Written into the note file's front matter
  /// so the order survives per-note saves.
  int order;

  /// Base name of this note's Markdown file on disk, or null when the
  /// note has never been saved (or the store is not file-backed).
  /// Bookkeeping for the file layer only: it lets a save replace or
  /// move exactly this note's file and no other.
  String? fileName;

  /// Whether the file named by [fileName] currently sits in the trash
  /// folder (true) or the live notes folder (false).
  bool fileInTrash = false;

  /// Serialises to the exact 0.1.0 field set (the store-level `order`
  /// array in [NoteStore.toJson] carries the drag order in JSON).
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'body': body,
    'tags': tags,
    'pinned': pinned,
    'created': created,
    'modified': modified,
  };

  /// A deep copy (the tag list is copied too).
  Note copy() => Note(
    id: id,
    title: title,
    body: body,
    tags: List<String>.of(tags),
    pinned: pinned,
    created: created,
    modified: modified,
    order: order,
  );

  /// Number of whitespace-separated words in title + body.
  int get wordCount =>
      '$title $body'.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

  /// Number of characters in title + body.
  int get charCount => title.length + body.length;
}

/// Counts describing the whole store, for the stats command and settings.
class StoreStats {
  const StoreStats({
    required this.notes,
    required this.trash,
    required this.tags,
    required this.pinned,
    required this.words,
    required this.characters,
  });

  /// Live notes.
  final int notes;

  /// Notes in the trash.
  final int trash;

  /// Distinct tags across live notes.
  final int tags;

  /// Pinned live notes.
  final int pinned;

  /// Total words across live notes.
  final int words;

  /// Total characters across live notes.
  final int characters;
}

/// The whole notebook: live notes, the trash, the id counter, and the
/// manual card order. All operations live here so the GUI and the CLI can
/// only ever do things the same way.
///
/// The in-memory model is authoritative while the program runs. When the
/// store is backed by a notes folder ([notesDir], set by [StoreFile.load]),
/// every mutation records which notes it touched, and [saveDirty] writes
/// just those notes' Markdown files — asynchronously, so the window never
/// waits on the disk to paint.
class NoteStore {
  NoteStore({
    List<Note>? notes,
    List<Note>? trash,
    List<int>? order,
    this.nextId = 1,
    this.notesDir,
  }) : notes = notes ?? <Note>[],
       trash = trash ?? <Note>[],
       order = order ?? <int>[] {
    _syncOrderFields();
  }

  /// An empty store.
  factory NoteStore.empty() => NoteStore();

  /// Tolerantly reads a store from decoded JSON. Unknown top-level fields
  /// are ignored. `next_id` is repaired so it always stays ahead of every
  /// existing id (live and trashed), even if the stored value is behind.
  factory NoteStore.fromJson(Object? value) {
    if (value is! Map) return NoteStore.empty();
    List<Note> readNotes(Object? raw) {
      if (raw is! List) return <Note>[];
      final result = <Note>[];
      for (final item in raw) {
        final note = Note.fromJson(item);
        if (note != null) result.add(note);
      }
      return result;
    }

    final notes = readNotes(value['notes']);
    final trash = readNotes(value['trash']);
    var highest = 0;
    for (final note in [...notes, ...trash]) {
      if (note.id > highest) highest = note.id;
    }
    final storedNext = value['next_id'];
    var nextId = storedNext is num ? storedNext.toInt() : 1;
    if (nextId <= highest) nextId = highest + 1;
    if (nextId < 1) nextId = 1;
    final rawOrder = value['order'];
    final order = <int>[];
    if (rawOrder is List) {
      for (final item in rawOrder) {
        if (item is num) order.add(item.toInt());
      }
    }
    // When the export carries no store-level order, fall back to each
    // note's own `order` value (the Markdown front matter has one).
    if (order.isEmpty && notes.length > 1) {
      final sorted = [...notes]..sort((a, b) => a.order.compareTo(b.order));
      order.addAll(sorted.map((n) => n.id));
    }
    return NoteStore(notes: notes, trash: trash, order: order, nextId: nextId);
  }

  /// Live notes, in stored (insertion) order. Use [list] for display order.
  List<Note> notes;

  /// Deleted notes, kept until restored or deleted forever.
  List<Note> trash;

  /// Manual display order of live note ids (see [SortMode.manual]).
  List<int> order;

  /// The id the next new note will get.
  int nextId;

  /// Set by [StoreFile.load] when an old `notes.json` existed but could
  /// not be read, and was quarantined instead of being overwritten.
  bool wasCorrupt = false;

  /// Set by [StoreFile.load] when there were no notes on disk yet.
  bool wasMissing = false;

  /// Path of the `notes` folder backing this store, or null for a purely
  /// in-memory store (most tests). Trashed notes live in its `trash`
  /// subfolder. Set by [StoreFile.load]; saves are no-ops without it.
  String? notesDir;

  /// Ids of notes whose files need (re)writing at the next [saveDirty],
  /// in whichever folder (live or trash) the note currently sits.
  final Set<int> _dirtyIds = <int>{};

  /// Full paths of note files to delete at the next [saveDirty] —
  /// notes deleted forever, and emptied trash.
  final Set<String> _pendingFileDeletes = <String>{};

  /// Tail of the save queue: saves run one after another, never on top
  /// of each other, so two saves can never fight over the same file.
  Future<void> _saveTail = Future<void>.value();

  /// Whether any note file still needs writing or deleting.
  bool get hasUnsavedChanges =>
      _dirtyIds.isNotEmpty || _pendingFileDeletes.isNotEmpty;

  /// Marks a note's file for (re)writing at the next save.
  void _markDirty(Note note) => _dirtyIds.add(note.id);

  /// Keeps every live note's [Note.order] field in step with the
  /// [order] list: a note's field is its index in the list, and notes
  /// missing from the list go after it in their current sequence.
  void _syncOrderFields() {
    final byId = <int, Note>{for (final note in notes) note.id: note};
    var index = 0;
    final placed = <int>{};
    for (final id in order) {
      final note = byId[id];
      if (note == null) continue;
      note.order = index++;
      placed.add(id);
    }
    for (final note in notes) {
      if (!placed.contains(note.id)) note.order = index++;
    }
  }

  /// The folder a note's file belongs in right now: the trash folder
  /// for trashed notes, the notes folder for live ones. Null when this
  /// store is not file-backed.
  String? _folderFor(Note note) {
    final dir = notesDir;
    if (dir == null) return null;
    if (trash.any((n) => n.id == note.id)) {
      return '$dir${Platform.pathSeparator}trash';
    }
    return dir;
  }

  /// Writes every note file touched since the last save — and only
  /// those — plus any pending file deletions. Each file is written
  /// atomically (a `.tmp` sibling, then a rename over the real name), a
  /// title change renames the note's file, and a note that moved
  /// between the notes folder and the trash takes its file along.
  ///
  /// Saves are queued: a second call while one is running waits its
  /// turn and then writes whatever is dirty by then. A failed write
  /// puts its note back on the dirty list (nothing is silently dropped)
  /// and the error is reported to the caller.
  Future<void> saveDirty() {
    final run = _saveTail.then((_) => _saveDirtyNow());
    _saveTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _saveDirtyNow() async {
    if (notesDir == null) {
      _dirtyIds.clear();
      _pendingFileDeletes.clear();
      return;
    }
    final ids = _dirtyIds.toList();
    _dirtyIds.clear();
    final deletes = _pendingFileDeletes.toList();
    _pendingFileDeletes.clear();
    Object? firstError;
    for (final id in ids) {
      final note = get(id) ?? getTrashed(id);
      if (note == null) continue; // gone from memory too; nothing to write
      try {
        await _writeNoteFile(note);
      } on Exception catch (e) {
        firstError ??= e;
        _dirtyIds.add(id); // still unsaved: a later save retries it
      }
    }
    for (final path in deletes) {
      try {
        await File(path).delete();
      } on Exception {
        // Already gone, or a leftover file that would not delete: it is
        // untidy, not data loss, and not worth failing the save over.
      }
    }
    if (firstError != null) throw firstError;
  }

  /// Writes one note's Markdown file into its current folder, removing
  /// the note's previous file when the name or folder changed (a rename
  /// from a title change, or a move to or from the trash).
  Future<void> _writeNoteFile(Note note) async {
    final folder = _folderFor(note);
    if (folder == null) return;
    await Directory(folder).create(recursive: true);
    final name = noteFileName(note);
    final target = File('$folder${Platform.pathSeparator}$name');
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(encodeNoteFile(note));
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // Windows will not rename over an existing file; remove the old
      // one and retry. The new data is safe in the .tmp file until here.
      try {
        await target.delete();
      } on FileSystemException {
        // The target may simply not exist yet (a first save racing the
        // rename on some filesystems); the retry below decides.
      }
      await tmp.rename(target.path);
    }
    final oldName = note.fileName;
    if (oldName != null) {
      final oldFolder = note.fileInTrash
          ? '${notesDir!}${Platform.pathSeparator}trash'
          : notesDir!;
      final oldPath = '$oldFolder${Platform.pathSeparator}$oldName';
      if (oldPath != target.path) {
        try {
          await File(oldPath).delete();
        } on FileSystemException {
          // Same reasoning as the pending deletes: tidy-up, not data.
        }
      }
    }
    note.fileName = name;
    note.fileInTrash = trash.any((n) => n.id == note.id);
  }

  /// Queues a note's on-disk file for deletion at the next save. Called
  /// by the operations that remove a note from memory for good.
  void _queueFileDelete(Note note) {
    final dir = notesDir;
    final name = note.fileName;
    if (dir == null || name == null) return;
    final folder = note.fileInTrash
        ? '$dir${Platform.pathSeparator}trash'
        : dir;
    _pendingFileDeletes.add('$folder${Platform.pathSeparator}$name');
    note.fileName = null;
  }

  /// Serialises to the 0.1.0 file shape, plus the store-level `order`.
  Map<String, Object?> toJson() => <String, Object?>{
    'next_id': nextId,
    'notes': notes.map((n) => n.toJson()).toList(),
    'trash': trash.map((n) => n.toJson()).toList(),
    'order': order,
  };

  /// Hands out the next id and advances the counter.
  int allocId() {
    final id = nextId < 1 ? 1 : nextId;
    nextId = id + 1;
    return id;
  }

  int _indexOf(int id) => notes.indexWhere((n) => n.id == id);

  /// Finds a live note by id, or null.
  Note? get(int id) {
    final i = _indexOf(id);
    return i < 0 ? null : notes[i];
  }

  /// Finds a trashed note by id, or null.
  Note? getTrashed(int id) {
    final i = trash.indexWhere((n) => n.id == id);
    return i < 0 ? null : trash[i];
  }

  /// Adds a note and returns it. An empty title becomes "Untitled note".
  Note add({
    required String title,
    String body = '',
    Iterable<String> tags = const <String>[],
    required int now,
  }) {
    final note = Note(
      id: allocId(),
      title: title.trim().isEmpty ? 'Untitled note' : title,
      body: body,
      tags: normalizeTags(tags),
      pinned: false,
      created: now,
      modified: now,
      order: notes.length,
    );
    notes.add(note);
    _markDirty(note);
    return note;
  }

  /// Updates the given fields of a live note. `modified` is only bumped
  /// when something actually changed. Returns the note, or null.
  Note? update(
    int id, {
    String? title,
    String? body,
    Iterable<String>? tags,
    required int now,
  }) {
    final note = get(id);
    if (note == null) return null;
    var changed = false;
    if (title != null && title != note.title) {
      note.title = title.trim().isEmpty ? 'Untitled note' : title;
      changed = true;
    }
    if (body != null && body != note.body) {
      note.body = body;
      changed = true;
    }
    if (tags != null) {
      final cleaned = normalizeTags(tags);
      if (cleaned.join('\u0001') != note.tags.join('\u0001')) {
        note.tags = cleaned;
        changed = true;
      }
    }
    if (changed) {
      note.modified = now;
      _markDirty(note);
    }
    return note;
  }

  /// Moves a live note to the trash. Returns false when not found.
  bool delete(int id) {
    final i = _indexOf(id);
    if (i < 0) return false;
    final note = notes.removeAt(i);
    trash.add(note);
    order.remove(id);
    _syncOrderFields();
    _markDirty(note); // its file moves to the trash folder on save
    return true;
  }

  /// Moves a trashed note back to the live notes. Returns false when the
  /// id is not in the trash.
  bool restore(int id) {
    final i = trash.indexWhere((n) => n.id == id);
    if (i < 0) return false;
    final note = trash.removeAt(i);
    note.order = notes.length;
    notes.add(note);
    _markDirty(note); // its file moves back to the notes folder on save
    return true;
  }

  /// Removes a trashed note permanently. Returns false when not found.
  bool deleteForever(int id) {
    final i = trash.indexWhere((n) => n.id == id);
    if (i < 0) return false;
    _queueFileDelete(trash.removeAt(i));
    return true;
  }

  /// Permanently removes everything in the trash.
  void emptyTrash() {
    for (final note in trash) {
      _queueFileDelete(note);
    }
    trash.clear();
  }

  /// Moves every live note to the trash. Returns how many were moved.
  int deleteAll() {
    final count = notes.length;
    for (final note in notes) {
      _markDirty(note); // each file moves to the trash folder on save
    }
    trash.addAll(notes);
    notes.clear();
    order.clear();
    return count;
  }

  /// Adds a tag to a live note. Returns false when the note is missing or
  /// the tag cleans up to nothing.
  bool addTag(int id, String rawTag, {required int now}) {
    final note = get(id);
    final tag = normalizeTag(rawTag);
    if (note == null || tag.isEmpty) return false;
    if (note.tags.contains(tag)) return true;
    note.tags = normalizeTags([...note.tags, tag]);
    note.modified = now;
    _markDirty(note);
    return true;
  }

  /// Removes a tag from a live note. Returns false when not found.
  bool removeTag(int id, String rawTag, {required int now}) {
    final note = get(id);
    final tag = normalizeTag(rawTag);
    if (note == null || !note.tags.contains(tag)) return false;
    note.tags = note.tags.where((t) => t != tag).toList();
    note.modified = now;
    _markDirty(note);
    return true;
  }

  /// Renames a tag on every live note; renaming onto an existing tag merges
  /// them (tags are normalised, so duplicates disappear). Returns how many
  /// notes carried the old tag.
  int renameTag(String oldRaw, String newRaw, {required int now}) {
    final oldTag = normalizeTag(oldRaw);
    final newTag = normalizeTag(newRaw);
    if (oldTag.isEmpty || newTag.isEmpty || oldTag == newTag) return 0;
    var count = 0;
    for (final note in notes) {
      if (!note.tags.contains(oldTag)) continue;
      note.tags = normalizeTags(note.tags.map((t) => t == oldTag ? newTag : t));
      note.modified = now;
      _markDirty(note);
      count++;
    }
    return count;
  }

  /// Every tag used by live notes, with its note count, sorted by name.
  List<MapEntry<String, int>> allTags() {
    final counts = <String, int>{};
    for (final note in notes) {
      for (final tag in note.tags) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final entries = counts.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }

  /// Pins or unpins a live note. Returns false when not found.
  bool setPinned(int id, {required bool pinned, required int now}) {
    final note = get(id);
    if (note == null) return false;
    if (note.pinned != pinned) {
      note.pinned = pinned;
      note.modified = now;
      _markDirty(note);
    }
    return true;
  }

  /// Copies a live note (new id, " copy" added to the title, not pinned).
  /// Returns the copy, or null when the source is missing.
  Note? duplicate(int id, {required int now}) {
    final source = get(id);
    if (source == null) return null;
    final copy = Note(
      id: allocId(),
      title: '${source.title} copy',
      body: source.body,
      tags: List<String>.of(source.tags),
      pinned: false,
      created: now,
      modified: now,
      order: notes.length,
    );
    notes.add(copy);
    _markDirty(copy);
    return copy;
  }

  /// Records a manual order: the given live ids, in display sequence.
  /// Ids that are not live are dropped; any live note missing from the
  /// list is appended in its current relative order.
  void reorder(List<int> ids) {
    final live = notes.map((n) => n.id).toSet();
    final result = <int>[];
    for (final id in ids) {
      if (live.contains(id) && !result.contains(id)) result.add(id);
    }
    for (final note in notes) {
      if (!result.contains(note.id)) result.add(note.id);
    }
    order = result;
    _syncOrderFields();
    // The order lives in each note file's front matter, so every live
    // note's file needs rewriting even if only some positions changed.
    for (final note in notes) {
      _markDirty(note);
    }
  }

  bool _matches(Note note, String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return note.title.toLowerCase().contains(q) ||
        note.body.toLowerCase().contains(q) ||
        note.tags.any((t) => t.contains(q));
  }

  /// The display list: filtered by search text and/or tag, sorted as asked,
  /// pinned notes always first within each sort.
  ///
  /// [tag] filters to one (normalised) tag; [untagged] filters to notes
  /// with no tags. Search matches title, body, and tags — but callers that
  /// display the result must still only ever show titles (see the note on
  /// [Note.title]).
  List<Note> list({
    String search = '',
    String? tag,
    bool untagged = false,
    SortMode sort = SortMode.modifiedDesc,
  }) {
    final wantedTag = tag == null ? null : normalizeTag(tag);
    final result = notes.where((note) {
      if (untagged && note.tags.isNotEmpty) return false;
      if (wantedTag != null && !note.tags.contains(wantedTag)) return false;
      return _matches(note, search.trim());
    }).toList();
    final orderIndex = <int, int>{};
    for (var i = 0; i < order.length; i++) {
      orderIndex[order[i]] = i;
    }
    int compare(Note a, Note b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      switch (sort) {
        case SortMode.modifiedDesc:
          return b.modified.compareTo(a.modified);
        case SortMode.titleAsc:
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case SortMode.createdDesc:
          return b.created.compareTo(a.created);
        case SortMode.manual:
          final ai = orderIndex[a.id] ?? 1 << 30;
          final bi = orderIndex[b.id] ?? 1 << 30;
          if (ai != bi) return ai.compareTo(bi);
          return b.modified.compareTo(a.modified);
      }
    }

    result.sort(compare);
    return result;
  }

  /// Counts for the whole store.
  StoreStats stats() {
    var words = 0;
    var characters = 0;
    var pinned = 0;
    for (final note in notes) {
      words += note.wordCount;
      characters += note.charCount;
      if (note.pinned) pinned++;
    }
    return StoreStats(
      notes: notes.length,
      trash: trash.length,
      tags: allTags().length,
      pinned: pinned,
      words: words,
      characters: characters,
    );
  }

  /// The whole store as JSON text (the export format is the data format).
  String exportJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Merges notes from exported JSON text: every imported note gets a
  /// fresh id, so importing never overwrites anything. Returns how many
  /// notes were imported. Throws [FormatException] on unreadable input or
  /// input that is not a TermiNote export.
  int importJson(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map || decoded['notes'] is! List) {
      throw const FormatException('not a TermiNote export file');
    }
    final incoming = NoteStore.fromJson(decoded);
    var count = 0;
    for (final note in incoming.notes) {
      final copy = note.copy()
        ..id = allocId()
        ..order = notes.length
        ..fileName = null;
      notes.add(copy);
      _markDirty(copy);
      count++;
    }
    return count;
  }
}

/// Where the notes live on disk, and loading them.
///
/// The data directory holds a `notes` folder (one Markdown file per
/// note, trashed notes in `notes/trash`), a `settings.json`, and —
/// only until the automatic one-time conversion — a pre-0.3.0
/// `notes.json`.
class StoreFile {
  /// Resolves the data directory:
  ///
  /// 1. The `TERMINOTE_DATA` environment variable, when set. Older
  ///    versions expected it to name the `notes.json` file itself, so a
  ///    value ending in `.json` resolves to that file's folder; any
  ///    other value is taken as the data directory itself.
  /// 2. Portable mode: `portable.txt` beside the executable puts the
  ///    data in the executable's folder.
  /// 3. On Windows: `%LOCALAPPDATA%\TermiNote`.
  /// 4. Anywhere else (development machines): a `terminote` folder
  ///    inside the system temp folder.
  ///
  /// [environment] and [executablePath] are injectable for tests.
  static String resolveDataDir({
    Map<String, String>? environment,
    String? executablePath,
  }) {
    final env = environment ?? Platform.environment;
    final override = env['TERMINOTE_DATA'];
    if (override != null && override.isNotEmpty) {
      if (override.toLowerCase().endsWith('.json')) {
        return File(override).parent.path;
      }
      return override;
    }
    final exePath = executablePath ?? Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    if (File('$exeDir${Platform.pathSeparator}portable.txt').existsSync()) {
      return exeDir;
    }
    if (Platform.isWindows) {
      final localAppData = env['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return '$localAppData\\TermiNote';
      }
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}terminote';
  }

  /// The `notes` folder inside a data directory.
  static String notesDirFor(String dataDir) =>
      '$dataDir${Platform.pathSeparator}notes';

  /// The trash subfolder inside a data directory's `notes` folder.
  static String trashDirFor(String dataDir) =>
      '${notesDirFor(dataDir)}${Platform.pathSeparator}trash';

  /// The pre-0.3.0 single data file inside a data directory (the
  /// migration source, and where its backup/quarantine copies land).
  static String legacyJsonPathFor(String dataDir) =>
      '$dataDir${Platform.pathSeparator}notes.json';

  /// Loads the store from the data directory at [dataDir]. Fully
  /// asynchronous: the caller never blocks on the disk.
  ///
  /// - No notes yet: an empty store with `wasMissing` set.
  /// - Markdown notes present: they are read tolerantly (see
  ///   [decodeNoteFile]); ids are repaired so every note has a unique
  ///   one and `nextId` stays ahead of them all.
  /// - A `notes.json` from an older version and no Markdown notes yet:
  ///   the automatic one-time migration runs — every note (and trash
  ///   entry) is written as a Markdown file, and `notes.json` is
  ///   renamed to `notes.json.migrated.bak` (`.bak2`, `.bak3`, … when
  ///   that name is taken). The old file is never deleted.
  /// - A `notes.json` that cannot be read: it is renamed to
  ///   `notes.json.corrupt-<now>` beside itself (the original bytes are
  ///   kept), an empty store is returned and `wasCorrupt` is set.
  static Future<NoteStore> load(String dataDir, {int? now}) async {
    final notesDir = notesDirFor(dataDir);
    final migrated = await _migrateLegacyJson(dataDir, now: now);
    if (migrated != null) return migrated;

    final notes = await _scanFolder(Directory(notesDir));
    final trash = await _scanFolder(Directory(trashDirFor(dataDir)));
    // The NoteStore constructor syncs the order fields from its order
    // list, which is not known yet at this point — that would overwrite
    // the values the files themselves carried. Keep them aside and put
    // them back before the order list is derived below.
    final parsedOrder = <Note, int>{
      for (final note in <Note>[...notes, ...trash]) note: note.order,
    };
    final store = NoteStore(notes: notes, trash: trash)..notesDir = notesDir;
    _repairLoadedIds(store);
    for (final note in <Note>[...store.notes, ...store.trash]) {
      final value = parsedOrder[note];
      if (value != null) note.order = value;
    }
    // The manual order comes from the front matter: live notes sorted
    // by their stored order value (ties broken by id, so the result is
    // stable) become the store's order list.
    final byOrder = [...store.notes]
      ..sort((a, b) {
        final byOrderValue = a.order.compareTo(b.order);
        return byOrderValue != 0 ? byOrderValue : a.id.compareTo(b.id);
      });
    store.order = byOrder.map((n) => n.id).toList();
    store._syncOrderFields();
    store.wasMissing = notes.isEmpty && trash.isEmpty;
    return store;
  }

  /// Runs the one-time `notes.json` conversion when it applies and
  /// returns the migrated store. Returns null when there is nothing to
  /// migrate (no legacy file, or Markdown notes already exist — in
  /// which case the legacy file is simply left where it is).
  static Future<NoteStore?> _migrateLegacyJson(
    String dataDir, {
    int? now,
  }) async {
    final notesDir = notesDirFor(dataDir);
    final legacyFile = File(legacyJsonPathFor(dataDir));
    List<int> legacyBytes;
    try {
      legacyBytes = await legacyFile.readAsBytes();
    } on FileSystemException {
      return null; // no legacy file (the normal case after migration)
    }
    if (await _folderHasMarkdown(Directory(notesDir))) return null;

    NoteStore store;
    try {
      // utf8.decode is strict on purpose: a file whose bytes are not
      // even valid text counts as damaged and is quarantined below.
      final decoded = jsonDecode(utf8.decode(legacyBytes));
      if (decoded is! Map) {
        throw const FormatException('top level is not an object');
      }
      store = NoteStore.fromJson(decoded);
    } on Exception {
      // The existing quarantine behaviour: keep the damaged file's
      // bytes under a new name and start empty rather than crash.
      final stamp = now ?? nowSeconds();
      try {
        await legacyFile.rename('${legacyFile.path}.corrupt-$stamp');
      } on FileSystemException {
        // If even the rename fails, still start empty; nothing has
        // overwritten the damaged file.
      }
      return NoteStore.empty()
        ..notesDir = notesDir
        ..wasCorrupt = true;
    }

    store.notesDir = notesDir;
    // An old file can carry a note id of 0 (or a repeated id); repair
    // those now, before any file is written, so the migrated store is
    // as sound in memory as a normal load would make it.
    _repairLoadedIds(store);
    // fromJson built the notes without file bookkeeping; writing every
    // note (and trash entry) through the normal save path produces the
    // Markdown files, trash files included.
    for (final note in [...store.notes, ...store.trash]) {
      store._markDirty(note);
    }
    await store.saveDirty();

    // Keep the old file as a backup — never delete it. First free name
    // in: notes.json.migrated.bak, notes.json.migrated.bak2, …
    var backup = File('${legacyFile.path}.migrated.bak');
    var suffix = 2;
    while (await _fileExists(backup)) {
      backup = File('${legacyFile.path}.migrated.bak$suffix');
      suffix++;
    }
    try {
      await legacyFile.rename(backup.path);
    } on FileSystemException {
      // The notes are safely converted either way; a backup that could
      // not be renamed stays as notes.json and is ignored from now on
      // (Markdown notes exist, so migration will not run again).
    }
    return store;
  }

  /// Reads every note file in [dir] (missing folder: no notes). File
  /// names are processed in sorted order so loading is deterministic.
  static Future<List<Note>> _scanFolder(Directory dir) async {
    final files = <File>[];
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        // Only real note files: .md, not hidden, not a temp leftover.
        if (name.startsWith('.') || name.startsWith('~')) continue;
        if (!name.toLowerCase().endsWith('.md')) continue;
        files.add(entity);
      }
    } on FileSystemException {
      return <Note>[]; // the folder simply is not there yet
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final inTrash = dir.path.endsWith('trash');
    final notes = <Note>[];
    for (final file in files) {
      var modifiedSeconds = 0;
      try {
        // Load-time only (once at startup), never on a paint/save path.
        modifiedSeconds =
            // ignore: avoid_slow_async_io
            (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
      } on FileSystemException {
        // No timestamp available; the fallbacks just stay 0.
      }
      String text;
      try {
        // Malformed bytes are replaced, never fatal: the note's text
        // survives even a damaged file.
        text = await file.readAsString();
      } on Exception {
        try {
          text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
        } on Exception {
          continue; // truly unreadable: skip it, lose nothing else
        }
      }
      final name = file.uri.pathSegments.last;
      notes.add(
        decodeNoteFile(
          text,
          fileName: name,
          fileModifiedSeconds: modifiedSeconds,
        )..fileInTrash = inTrash,
      );
    }
    return notes;
  }

  /// True when [dir] holds at least one note file (see [_scanFolder]
  /// for what counts as one).
  static Future<bool> _folderHasMarkdown(Directory dir) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('.') || name.startsWith('~')) continue;
        if (name.toLowerCase().endsWith('.md')) return true;
      }
    } on FileSystemException {
      return false;
    }
    return false;
  }

  static Future<bool> _fileExists(File file) async {
    try {
      // Startup migration probe only; keeps the sync exists() off disk.
      // ignore: avoid_slow_async_io
      await file.lastModified();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Repairs ids after a folder scan: notes that arrived without a
  /// usable id (0) or with an id another file already claimed get fresh
  /// ids above the highest one in use, and `nextId` is set ahead of
  /// every id, live and trashed, so ids are never reused.
  static void _repairLoadedIds(NoteStore store) {
    var highest = 0;
    for (final note in [...store.notes, ...store.trash]) {
      if (note.id > highest) highest = note.id;
    }
    final seen = <int>{};
    for (final note in [...store.notes, ...store.trash]) {
      if (note.id <= 0 || !seen.add(note.id)) {
        highest++;
        note.id = highest;
        seen.add(note.id);
      }
    }
    store.nextId = highest + 1;
  }
}
