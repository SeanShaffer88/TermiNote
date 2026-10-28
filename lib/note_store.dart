/// TermiNote data layer: the note model, the store, every note operation,
/// and reading/writing the on-disk JSON file.
///
/// This file has no Flutter imports on purpose, so the whole thing is plain
/// Dart and fully testable. The GUI and the CLI both work through these
/// operations; there are no GUI-only capabilities.
///
/// File format (unchanged from TermiNote 0.1.0, so existing notes carry
/// over untouched):
///
/// ```json
/// {"next_id": 3,
///  "notes": [{"id": 1, "title": "...", "body": "...", "tags": ["a"],
///             "pinned": false, "created": 1700000000,
///             "modified": 1700000000}],
///  "trash": [],
///  "order": [2, 1]}
/// ```
///
/// Times are unix seconds. The `order` array (manual card order) is the one
/// addition: 0.1.x readers ignore unknown fields, and this reader ignores
/// unknown fields too, so the two versions can share a file.
library;

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

  /// Serialises to the exact 0.1.0 field set.
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
class NoteStore {
  NoteStore({
    List<Note>? notes,
    List<Note>? trash,
    List<int>? order,
    this.nextId = 1,
  }) : notes = notes ?? <Note>[],
       trash = trash ?? <Note>[],
       order = order ?? <int>[];

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

  /// Set by [StoreFile.load] when the data file existed but could not be
  /// read, and was quarantined instead of being overwritten.
  bool wasCorrupt = false;

  /// Set by [StoreFile.load] when there was no data file yet.
  bool wasMissing = false;

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
    );
    notes.add(note);
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
    if (changed) note.modified = now;
    return note;
  }

  /// Moves a live note to the trash. Returns false when not found.
  bool delete(int id) {
    final i = _indexOf(id);
    if (i < 0) return false;
    trash.add(notes.removeAt(i));
    order.remove(id);
    return true;
  }

  /// Moves a trashed note back to the live notes. Returns false when the
  /// id is not in the trash.
  bool restore(int id) {
    final i = trash.indexWhere((n) => n.id == id);
    if (i < 0) return false;
    notes.add(trash.removeAt(i));
    return true;
  }

  /// Removes a trashed note permanently. Returns false when not found.
  bool deleteForever(int id) {
    final i = trash.indexWhere((n) => n.id == id);
    if (i < 0) return false;
    trash.removeAt(i);
    return true;
  }

  /// Permanently removes everything in the trash.
  void emptyTrash() => trash.clear();

  /// Moves every live note to the trash. Returns how many were moved.
  int deleteAll() {
    final count = notes.length;
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
    return true;
  }

  /// Removes a tag from a live note. Returns false when not found.
  bool removeTag(int id, String rawTag, {required int now}) {
    final note = get(id);
    final tag = normalizeTag(rawTag);
    if (note == null || !note.tags.contains(tag)) return false;
    note.tags = note.tags.where((t) => t != tag).toList();
    note.modified = now;
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
    );
    notes.add(copy);
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
      final copy = note.copy()..id = allocId();
      notes.add(copy);
      count++;
    }
    return count;
  }
}

/// Where the data file lives, and safe reading/writing of it.
class StoreFile {
  /// Resolves the data file path:
  ///
  /// 1. The `TERMINOTE_DATA` environment variable, when set.
  /// 2. Portable mode: `portable.txt` beside the executable puts
  ///    `notes.json` in the executable's folder.
  /// 3. On Windows: `%LOCALAPPDATA%\TermiNote\notes.json`.
  /// 4. Anywhere else (development machines): a `terminote` folder inside
  ///    the system temp folder.
  ///
  /// [environment] and [executablePath] are injectable for tests.
  static String resolvePath({
    Map<String, String>? environment,
    String? executablePath,
  }) {
    final env = environment ?? Platform.environment;
    final override = env['TERMINOTE_DATA'];
    if (override != null && override.isNotEmpty) return override;
    final exePath = executablePath ?? Platform.resolvedExecutable;
    final exeDir = File(exePath).parent.path;
    if (File('$exeDir${Platform.pathSeparator}portable.txt').existsSync()) {
      return '$exeDir${Platform.pathSeparator}notes.json';
    }
    if (Platform.isWindows) {
      final localAppData = env['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return '$localAppData\\TermiNote\\notes.json';
      }
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}terminote'
        '${Platform.pathSeparator}notes.json';
  }

  /// Loads the store at [path].
  ///
  /// - Missing file: an empty store with `wasMissing` set.
  /// - Readable, valid file: the stored notes.
  /// - Existing but unparseable file: the file is renamed to
  ///   `notes.json.corrupt-<now>` beside itself (the original bytes are
  ///   kept), an empty store is returned and `wasCorrupt` is set.
  static NoteStore load(String path, {int? now}) {
    final file = File(path);
    if (!file.existsSync()) {
      return NoteStore.empty()..wasMissing = true;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) {
        throw const FormatException('top level is not an object');
      }
      return NoteStore.fromJson(decoded);
    } on Exception {
      final stamp = now ?? nowSeconds();
      try {
        file.renameSync('$path.corrupt-$stamp');
      } on FileSystemException {
        // If even the rename fails, still start empty rather than crash;
        // the next save writes a fresh file.
      }
      return NoteStore.empty()..wasCorrupt = true;
    }
  }

  /// Saves the store at [path] atomically: the JSON is written to
  /// `<path>.tmp` first and then renamed over the real file, so a crash
  /// or power cut mid-save cannot leave a half-written notes file.
  static void save(String path, NoteStore store) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(store.toJson()),
    );
    try {
      tmp.renameSync(path);
    } on FileSystemException {
      // Windows will not rename over an existing file; remove the old one
      // and retry. The new data is safe in the .tmp file until this point.
      if (file.existsSync()) file.deleteSync();
      tmp.renameSync(path);
    }
  }
}
