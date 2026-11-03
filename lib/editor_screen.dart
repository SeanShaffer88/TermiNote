/// The note editor page, pushed over the list like the phone app.
///
/// One big card: title, divider, tags, divider, then the body on faint
/// ruled lines that stay aligned to the text at every size. Changes save
/// automatically as you type (about 600 ms after the last keystroke);
/// the red check button saves, flashes "Saved", and goes back.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cli.dart';
import 'editor_ops.dart';
import 'main.dart';
import 'markdown.dart';
import 'markdown_view.dart';
import 'note_store.dart';
import 'theme.dart';

/// How "show this note's file in Explorer" is done; replaced in tests.
/// Answers true when the file manager was launched.
Future<bool> Function(String path) showInExplorerImpl = _showInExplorer;

Future<bool> _showInExplorer(String path) async {
  if (!io.Platform.isWindows) return false;
  try {
    // explorer.exe answers with exit code 1 even when it worked, so a
    // launched process is the success signal, not its exit code.
    await io.Process.run('explorer.exe', <String>['/select,', path]);
    return true;
  } on Exception {
    return false;
  }
}

/// Editor for one note. A null [note] means "new note" — it is created
/// in the store the moment the editor opens, so typing can autosave
/// from the first character, exactly like the phone app.
/// The note editor's view modes, after Ferrite: raw editing, a split
/// of raw text beside the rendered preview, or the rendered preview
/// alone.
enum _ViewMode { edit, split, preview }

class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.state, required this.note});

  /// Shared app state.
  final AppState state;

  /// The note to edit, or null for a new note.
  final Note? note;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final Note _note;
  late final TextEditingController _titleController;
  late final TextEditingController _tagsController;
  late final TextEditingController _bodyController;
  late final TextEditingController _findController;
  late final FocusNode _findFocus = FocusNode(onKeyEvent: _findFieldKey);

  /// Enter in the find field steps to the next match (Shift+Enter:
  /// the previous one). Handled at the focus node so it works the
  /// same whether or not the platform turns Enter into a submit
  /// action for the field; the field's onSubmitted covers the
  /// platforms that send an action without a key event.
  KeyEventResult _findFieldKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      _findStep(HardwareKeyboard.instance.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  final FocusNode _bodyFocus = FocusNode();
  final ScrollController _bodyScrollController = ScrollController();
  late double _fontSize;
  Timer? _debounce;
  bool _savedFlash = false;
  bool _isNew = false;

  // Find-in-note state: whether the find bar is open, the start offsets
  // of every match of the current query in the body text, and which
  // match is current (the one the count names and next/previous step
  // from). _findCurrent is -1 when there are no matches.
  bool _findOpen = false;
  List<({int start, int length})> _findMatches = <({int start, int length})>[];
  int _findCurrent = -1;

  // Find & replace extras: whether the query is treated as a regular
  // expression (the `.*` toggle), whether the replace row is showing,
  // and the replace field's controller.
  bool _findRegex = false;
  bool _replaceMode = false;
  late final TextEditingController _replaceController;

  // Guards the snippet expansion in _onBodyChanged against re-entry
  // (setting the body value fires the listener again).
  bool _expandingSnippet = false;

  // Editor view mode, Ferrite-style: Edit (raw text only), Split
  // (raw text and rendered preview side by side), or Preview
  // (rendered only). Editing tools and find work in Edit and Split;
  // find switches Preview back to Edit, like it did before.
  _ViewMode _mode = _ViewMode.edit;

  bool get _isPreview => _mode == _ViewMode.preview;

  // The last successfully saved contents of the three fields. The note
  // counts as dirty whenever the fields differ from this snapshot —
  // that is what the close confirmation asks about.
  String _savedTitle = '';
  String _savedTags = '';
  String _savedBody = '';

  // Set when the user chooses to throw unsaved changes away (in this
  // editor's close dialog, or the program's quit dialog), so dispose()
  // does not save them after all on its way out.
  bool _discarding = false;

  AppState get state => widget.state;
  NoteStore get store => widget.state.store;

  /// Line-height factor for the body text. The ruled lines are drawn from
  /// this same value, so they re-align whenever the size changes.
  static const double _lineFactor = 1.8;

  double get _lineHeight => _fontSize * _lineFactor;

  @override
  void initState() {
    super.initState();
    if (widget.note == null) {
      _isNew = true;
      _note = store.add(title: '', now: nowSeconds());
      unawaited(state.persist());
    } else {
      _note = widget.note!;
    }
    // A brand-new note opens with an empty title field (the store calls it
    // "Untitled note" as a placeholder until the user types one).
    _titleController = TextEditingController(text: _isNew ? '' : _note.title);
    _tagsController = TextEditingController(text: _note.tags.join(', '));
    _bodyController = _HighlightController(text: _note.body);
    // The line-number gutter repaints as the body scrolls.
    _bodyScrollController.addListener(() {
      if (mounted) setState(() {});
    });
    _findController = TextEditingController();
    _replaceController = TextEditingController();
    _fontSize = state.textSize;
    _bodyController.addListener(_onBodyChanged);
    _findController.addListener(_onFindQueryChanged);
    _savedTitle = _titleController.text;
    _savedTags = _tagsController.text;
    _savedBody = _bodyController.text;
    // Register with the app state so quitting the program can ask about
    // unsaved changes here before it closes (see AppState).
    state.registerEditor(
      flush: _flushForExit,
      discard: () {
        _discarding = true;
        // The user chose to throw the unsaved work away: the recovery
        // draft goes with it, or the next start would offer back the
        // very text that was just discarded on purpose.
        unawaited(store.deleteRecoveryDraft(_note.id));
      },
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // dispose() cannot wait on anything; the flush applies its
    // in-memory changes straight away and its disk write finishes on
    // its own (the exit path awaits the same flush properly).
    if (!_discarding) unawaited(_flush(closing: true));
    state.unregisterEditor();
    _titleController.dispose();
    _tagsController.dispose();
    _bodyController.dispose();
    _findController.dispose();
    _replaceController.dispose();
    _findFocus.dispose();
    _bodyFocus.dispose();
    _bodyScrollController.dispose();
    super.dispose();
  }

  /// True while any field differs from the last saved snapshot.
  bool get _isDirty =>
      _titleController.text != _savedTitle ||
      _tagsController.text != _savedTags ||
      _bodyController.text != _savedBody;

  /// Whether the last saved version of this note is completely empty —
  /// true for a brand-new note that has never been saved with content.
  bool get _savedIsBlank =>
      _savedTitle.trim().isEmpty &&
      _savedTags.trim().isEmpty &&
      _savedBody.trim().isEmpty;

  /// Saves pending changes right now, for the program-close check in
  /// [AppState]. The write is awaited, so when this returns true the
  /// note really is on disk. A failure reports false rather than
  /// throwing.
  Future<bool> _flushForExit() async {
    _debounce?.cancel();
    try {
      await _flush(closing: true);
      return true;
    } on Exception {
      return false;
    }
  }

  void _onBodyChanged() {
    // Snippet expansion: typing `;date`, `;time`, or `;now` in full
    // replaces the word with the stamp it names. Setting the value
    // fires this listener again, so the expansion is guarded.
    if (!_expandingSnippet) {
      final value = _bodyController.value;
      final selection = value.selection;
      if (selection.isValid && selection.isCollapsed) {
        final expanded = expandSnippet(
          value.text,
          selection.start,
          nowSeconds(),
        );
        if (expanded != null) {
          _expandingSnippet = true;
          _bodyController.value = TextEditingValue(
            text: expanded.text,
            selection: TextSelection.collapsed(offset: expanded.start),
          );
          _expandingSnippet = false;
        }
      }
    }
    if (mounted) setState(() {});
    // The find matches are offsets into this text: recompute them as
    // it changes (keeping the current match where it still exists).
    if (_findOpen) _refreshFindMatches(resetCurrent: false);
    _scheduleSave();
  }

  void _scheduleSave() {
    state.editorDirty = _isDirty;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_flushQuietly()),
    );
  }

  /// The debounced autosave. A failed write is not silently dropped —
  /// the store keeps the note on its dirty list and the next save (or
  /// the close/exit flush, which does report failure) retries it — but
  /// the timer callback itself has nobody to report to, so it just
  /// leaves the note marked dirty.
  Future<void> _flushQuietly() async {
    try {
      await _flush();
    } on Exception {
      state.editorDirty = _isDirty;
    }
  }

  /// Writes the field contents into the store and saves the note's
  /// file, then refreshes the saved snapshot, so the note is clean
  /// again. The in-memory update happens immediately; the returned
  /// future completes when the file write has finished.
  ///
  /// A new note the user left completely empty is removed again instead
  /// of cluttering the list with a blank "Untitled note" — but only when
  /// [closing] is true. A debounce save mid-edit must not delete the
  /// placeholder from under the user (they might be about to type).
  /// A snapshot of the note as the fields currently show it, for the
  /// crash-recovery draft: the same title the store would save (an
  /// empty title becomes "Untitled note"), the body and tags exactly
  /// as typed, and the note's pin state.
  Note _draftSnapshot() => Note(
    id: _note.id,
    title: _titleController.text.trim().isEmpty
        ? 'Untitled note'
        : _titleController.text,
    body: _bodyController.text,
    tags: parseTags(_tagsController.text),
    pinned: _note.pinned,
    created: _note.created,
    modified: nowSeconds(),
    order: _note.order,
  );

  Future<void> _flush({bool closing = false}) async {
    if (_isNew &&
        _titleController.text.trim().isEmpty &&
        _bodyController.text.trim().isEmpty) {
      if (!closing) return;
      store.delete(_note.id);
      store.deleteForever(_note.id);
      _isNew = false; // it is gone either way now
      await store.deleteRecoveryDraft(_note.id);
      await state.persist();
      return;
    }
    store.update(
      _note.id,
      title: _titleController.text,
      body: _bodyController.text,
      tags: parseTags(_tagsController.text),
      now: nowSeconds(),
    );
    _savedTitle = _titleController.text;
    _savedTags = _tagsController.text;
    _savedBody = _bodyController.text;
    state.editorDirty = false;
    await state.persist();
    // Crash-recovery draft: while the editor stays open, every
    // autosave also refreshes the draft, so a sudden close leaves the
    // latest text behind to offer back. Once the editor closes cleanly
    // (this flush is the final save), the draft is deleted instead —
    // the note itself is saved and the draft has done its job. The
    // draft rides the store's save queue behind the note's own write,
    // so it lands after the note file, never interleaved with it.
    if (closing) {
      await store.deleteRecoveryDraft(_note.id);
    } else {
      await store.saveRecoveryDraft(_draftSnapshot());
    }
  }

  /// Closing the editor (back arrow or Esc). With no unsaved changes
  /// this just saves and leaves, as before. With unsaved changes it asks
  /// first: save and close, discard the changes (the last saved version
  /// stays as it was), or keep editing.
  Future<void> _requestClose() async {
    if (!_isDirty) {
      _debounce?.cancel();
      await _flush(closing: true);
      if (mounted) Navigator.of(context).pop('saved');
      return;
    }
    final choice = await showUnsavedWorkDialog(
      context,
      title: 'Save before closing?',
      saveLabel: 'Save and close',
      saveTooltip: 'Save the changes and close the note',
      discardLabel: 'Discard changes',
      discardTooltip: 'Close without saving; the last saved version stays',
      keepLabel: 'Keep editing',
      keepTooltip: 'Go back to editing this note',
    );
    if (!mounted) return;
    if (choice == 'save') {
      _debounce?.cancel();
      await _flush(closing: true);
      if (mounted) Navigator.of(context).pop('saved');
    } else if (choice == 'discard') {
      _discarding = true;
      // The discarded text must not come back as a recovery offer.
      unawaited(store.deleteRecoveryDraft(_note.id));
      if (_isNew && _savedIsBlank) {
        // A new note that was never saved with content has no earlier
        // version to fall back to: remove the empty placeholder the
        // editor created when it opened.
        store.delete(_note.id);
        store.deleteForever(_note.id);
        await state.persist();
      }
      if (mounted) Navigator.of(context).pop('discarded');
    }
    // 'keep' or a dismissed dialog: stay in the editor.
  }

  Future<void> _checkAndPop() async {
    _debounce?.cancel();
    await _flush(closing: true);
    if (!mounted) return;
    setState(() => _savedFlash = true);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (mounted) Navigator.of(context).pop('saved');
  }

  void _saveFlashOnly() {
    _debounce?.cancel();
    unawaited(_flush());
    setState(() => _savedFlash = true);
    Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _savedFlash = false);
    });
  }

  /// Converts the body text into a numbered or bullet list — the
  /// selected lines when there is a selection, otherwise the whole
  /// body. Replaces the text through the controller, so the change
  /// autosaves and undoes (Ctrl+Z) like any other typing. Converting an
  /// already-converted list turns it back into plain text; that toggle
  /// lives in the shared functions in note_store.dart.
  /// Applies one Markdown formatting operation (see markdown.dart) to
  /// the body's current selection — or at the cursor when nothing is
  /// selected. Replaces the text through the controller, so the change
  /// autosaves and undoes (Ctrl+Z) like any other typing. The CLI's
  /// `format` command runs the same operation over a whole note.
  void _applyFormat(MdFormat format) {
    if (_isPreview) return;
    final value = _bodyController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final result = applyMarkdownFormat(value.text, start, end, format);
    _bodyController.value = TextEditingValue(
      text: result.text,
      selection: TextSelection(
        baseOffset: result.start,
        extentOffset: result.end,
      ),
    );
    _bodyFocus.requestFocus();
  }

  /// Switches the body area between Edit, Split, and Preview. What
  /// the preview shows is the field's current text, so it is always
  /// exactly what will be saved.
  void _setMode(_ViewMode mode) {
    if (mode == _mode) return;
    if (mode == _ViewMode.preview && _findOpen) _closeFind();
    setState(() => _mode = mode);
    if (mode != _ViewMode.preview) _bodyFocus.requestFocus();
  }

  void _convertBody({required bool numbered}) {
    final value = _bodyController.value;
    final text = value.text;
    final selection = value.selection;
    var start = 0;
    var end = text.length;
    if (selection.isValid && !selection.isCollapsed) {
      // Grow the selection out to whole lines: from the start of the
      // first touched line to the end of the last touched line. A
      // selection ending exactly at a line start does not pull that
      // extra line in.
      start = selection.start;
      while (start > 0 && text[start - 1] != '\n') {
        start--;
      }
      end = selection.end;
      if (end > start && text[end - 1] != '\n') {
        while (end < text.length && text[end] != '\n') {
          end++;
        }
      }
    }
    final segment = text.substring(start, end);
    final converted = numbered
        ? toNumberedList(segment)
        : toBulletList(segment);
    _bodyController.value = TextEditingValue(
      text: text.replaceRange(start, end, converted),
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + converted.length,
      ),
    );
  }

  // -- Find in this note -------------------------------------------------
  // Ctrl+F opens a slim bar under the toolbar: a plain substring search
  // over the body text, ignoring case (no regular expressions). Matches
  // recompute whenever the query or the body changes. Stepping to a
  // match selects it in the body field and scrolls the field to about
  // its line (lines are counted by line breaks, so wrapped lines make
  // the scroll approximate — the selection itself is exact).

  /// Opens the find bar (or, when it is already open, just puts the
  /// focus back in its field) and refreshes the matches.
  void _openFind() {
    if (_isPreview) setState(() => _mode = _ViewMode.edit);
    if (!_findOpen) {
      setState(() => _findOpen = true);
      _refreshFindMatches(resetCurrent: true);
      if (_findCurrent >= 0) _selectFindMatch();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
  }

  /// Closes the find bar and gives the body field the focus back.
  void _closeFind() {
    setState(() => _findOpen = false);
    _bodyFocus.requestFocus();
  }

  /// Esc closes the find bar while it is open; otherwise it is the
  /// editor's usual close request.
  void _handleEscape() {
    if (_findOpen) {
      _closeFind();
    } else {
      unawaited(_requestClose());
    }
  }

  /// The find query changed: recompute the matches, start again from
  /// the first one, and show it selected in the body.
  void _onFindQueryChanged() {
    if (!mounted || !_findOpen) return;
    setState(() => _refreshFindMatches(resetCurrent: true));
    if (_findCurrent >= 0) _selectFindMatch();
  }

  /// Recomputes [_findMatches] from the current query and body text.
  /// Matches do not overlap: after a match, the search continues after
  /// its end. With [resetCurrent] the current match becomes the first;
  /// otherwise it is kept where it was, clamped into range. When the
  /// regex toggle is on the query is a regular expression (still
  /// ignoring case); a pattern that does not parse simply finds
  /// nothing, it never throws into the editor.
  void _refreshFindMatches({required bool resetCurrent}) {
    final query = _findController.text;
    final body = _bodyController.text;
    final found = <({int start, int length})>[];
    if (query.isNotEmpty) {
      if (_findRegex) {
        try {
          final pattern = RegExp(query, caseSensitive: false);
          for (final match in pattern.allMatches(body)) {
            if (match.end == match.start) continue; // zero-width: skip
            found.add((start: match.start, length: match.end - match.start));
          }
        } on FormatException {
          // A half-typed pattern: no matches until it parses again.
        }
      } else {
        final haystack = body.toLowerCase();
        final needle = query.toLowerCase();
        var from = 0;
        while (from + needle.length <= haystack.length) {
          final hit = haystack.indexOf(needle, from);
          if (hit < 0) break;
          found.add((start: hit, length: needle.length));
          from = hit + needle.length;
        }
      }
    }
    _findMatches = found;
    if (found.isEmpty) {
      _findCurrent = -1;
    } else if (resetCurrent || _findCurrent < 0) {
      _findCurrent = 0;
    } else if (_findCurrent >= found.length) {
      _findCurrent = found.length - 1;
    }
  }

  /// Opens the find bar in replace mode (Ctrl+H).
  void _openReplace() {
    _openFind();
    if (!_replaceMode) setState(() => _replaceMode = true);
  }

  /// Replaces the current match with the replace field's text, then
  /// steps to the next match (which the recompute finds).
  void _replaceCurrent() {
    if (_findCurrent < 0 || _findCurrent >= _findMatches.length) return;
    final match = _findMatches[_findCurrent];
    final replacement = _replaceController.text;
    _bodyController.value = TextEditingValue(
      text: _bodyController.text.replaceRange(
        match.start,
        match.start + match.length,
        replacement,
      ),
      selection: TextSelection.collapsed(
        offset: match.start + replacement.length,
      ),
    );
    // The body listener already recomputed the matches against the
    // new text; show the next one if there is one.
    if (_findCurrent >= 0) _selectFindMatch();
    _bodyFocus.requestFocus();
  }

  /// Replaces every match with the replace field's text. The
  /// replacement is literal text in both plain and regex modes.
  void _replaceAll() {
    if (_findMatches.isEmpty) return;
    final replacement = _replaceController.text;
    var text = _bodyController.text;
    // Back to front, so earlier offsets stay valid while replacing.
    for (final match in _findMatches.reversed) {
      text = text.replaceRange(
        match.start,
        match.start + match.length,
        replacement,
      );
    }
    _bodyController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: 0),
    );
    _bodyFocus.requestFocus();
  }

  /// Steps to the next match (positive [delta]) or the previous one,
  /// wrapping around at both ends. With no matches it does nothing.
  void _findStep(int delta) {
    if (_findMatches.isEmpty) return;
    setState(() {
      _findCurrent = (_findCurrent + delta) % _findMatches.length;
      // Dart's % is already non-negative for a positive divisor; the
      // wrap is written out so the intent is plain.
      if (_findCurrent < 0) _findCurrent += _findMatches.length;
    });
    _selectFindMatch();
  }

  /// Selects the current match in the body field and scrolls the field
  /// to about the match's line.
  void _selectFindMatch() {
    if (_findCurrent < 0 || _findCurrent >= _findMatches.length) return;
    final match = _findMatches[_findCurrent];
    _bodyController.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.start + match.length,
    );
    _scrollToOffset(match.start);
  }

  /// Scrolls the body field to about the line holding [offset] (lines
  /// are counted by line breaks, so wrapped lines make the scroll
  /// approximate — the selection itself is exact).
  void _scrollToOffset(int offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_bodyScrollController.hasClients) return;
      final before = _bodyController.text.substring(0, offset);
      final line = '\n'.allMatches(before).length;
      final maxExtent = _bodyScrollController.position.maxScrollExtent;
      final target = (line * _lineHeight - _lineHeight).clamp(0.0, maxExtent);
      _bodyScrollController.jumpTo(target);
    });
  }

  /// Applies one of the shared line operations (see editor_ops.dart)
  /// to the body's current selection through the controller, so the
  /// change autosaves and undoes like typing.
  void _applyLineEdit(EditorEdit result) {
    _bodyController.value = TextEditingValue(
      text: result.text,
      selection: TextSelection(
        baseOffset: result.start,
        extentOffset: result.end,
      ),
    );
    _bodyFocus.requestFocus();
  }

  void _duplicateLines() {
    if (_isPreview) return;
    final value = _bodyController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _applyLineEdit(duplicateLines(value.text, start, end));
  }

  void _moveLines({required bool up}) {
    if (_isPreview) return;
    final value = _bodyController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _applyLineEdit(moveLines(value.text, start, end, up: up));
  }

  /// Ctrl+Shift+U: build (or rebuild) the note's table of contents
  /// from its headings — the same operation as the CLI's `toc`.
  void _insertToc() {
    if (_isPreview) return;
    final value = _bodyController.value;
    final updated = insertToc(value.text);
    if (updated == value.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Add a heading first — the contents list is built from headings.',
          ),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    _bodyController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: 0),
    );
    _bodyFocus.requestFocus();
  }

  void _goToLineShortcut() => unawaited(_goToLine());

  /// Ctrl+G: ask for a line number and jump to it, selecting the line.
  Future<void> _goToLine() async {
    if (_isPreview) return;
    final text = _bodyController.text;
    final lineCount = '\n'.allMatches(text).length + 1;
    final controller = TextEditingController();
    final line = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text(
          'Go to line',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          cursorColor: kAccent,
          decoration: InputDecoration(
            hintText: 'Line number (1 to $lineCount)',
            hintStyle: const TextStyle(color: kDim),
          ),
          onSubmitted: (value) =>
              Navigator.of(context).pop(int.tryParse(value.trim())),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel', style: TextStyle(color: kDim)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(controller.text.trim())),
            child: const Text('Go', style: TextStyle(color: kAccentText)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (line == null || !mounted) return;
    final target = line.clamp(1, lineCount);
    var offset = 0;
    for (var n = 1; n < target; n++) {
      offset = text.indexOf('\n', offset) + 1;
    }
    var lineEnd = text.indexOf('\n', offset);
    if (lineEnd < 0) lineEnd = text.length;
    _bodyController.selection = TextSelection(
      baseOffset: offset,
      extentOffset: lineEnd,
    );
    _scrollToOffset(offset);
    _bodyFocus.requestFocus();
  }

  /// The find bar's status words: "match 2 of 5", "no matches" for a
  /// query that found nothing, and nothing before anything is typed.
  String get _findStatus {
    if (_findController.text.isEmpty) return '';
    if (_findMatches.isEmpty) return 'no matches';
    return 'match ${_findCurrent + 1} of ${_findMatches.length}';
  }

  void _changeSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(12, 28);
    });
    state.textSize = _fontSize;
    unawaited(state.saveSettings());
  }

  void _togglePin() {
    store.setPinned(_note.id, pinned: !_note.pinned, now: nowSeconds());
    unawaited(state.persist());
    setState(() {});
  }

  void _duplicate() {
    // _flush applies its in-memory update immediately; only its disk
    // write is asynchronous, and the persist below queues behind it.
    unawaited(_flush());
    final copy = store.duplicate(_note.id, now: nowSeconds());
    unawaited(state.persist());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          copy == null ? 'Could not copy this note.' : 'Copied as a new note.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// F5: type the current date and time into the body at the cursor —
  /// the classic Notepad stamp, in the same format the note list uses
  /// for times. A selection is replaced by the stamp.
  void _insertStamp() {
    final stamp = formatStamp(nowSeconds());
    final value = _bodyController.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    _bodyController.value = TextEditingValue(
      text: value.text.replaceRange(start, end, stamp),
      selection: TextSelection.collapsed(offset: start + stamp.length),
    );
  }

  /// The words-and-characters line under the editor card, now with a
  /// reading time (200 words a minute) once the note has any words.
  String get _countLabel {
    final text = _bodyController.text;
    final words = text.trim().isEmpty
        ? 0
        : RegExp(r'\S+').allMatches(text).length;
    final chars = text.length;
    final base =
        '$words ${words == 1 ? 'word' : 'words'} · '
        '$chars ${chars == 1 ? 'character' : 'characters'}';
    if (words == 0) return base;
    final minutes = noteStats(text).readingMinutes;
    return '$base · ~$minutes min read';
  }

  /// The FILE toolbar button: save first (so the file on disk is the
  /// text on screen), then show this note's Markdown file in Explorer.
  Future<void> _showFileInExplorer() async {
    final untouchedNew =
        _isNew &&
        _titleController.text.trim().isEmpty &&
        _bodyController.text.trim().isEmpty;
    if (!untouchedNew) await _flush();
    if (!mounted) return;
    final path = store.filePathFor(_note);
    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This note has no file yet.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final ok = await showInExplorerImpl(path);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not show the file in Explorer.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _delete() {
    _debounce?.cancel();
    final untouchedNew =
        _isNew &&
        _titleController.text.trim().isEmpty &&
        _bodyController.text.trim().isEmpty;
    // As in _duplicate: the flush's in-memory part runs straight away,
    // so the delete below already sees the final field contents.
    unawaited(_flush(closing: true));
    if (untouchedNew) {
      // _flush already discarded the blank new note; there is nothing in
      // the trash to undo, so just go back.
      Navigator.of(context).pop('saved');
      return;
    }
    store.delete(_note.id);
    unawaited(state.persist());
    Navigator.of(context).pop('deleted');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ScanlineBackground(
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
            const SingleActivator(LogicalKeyboardKey.keyS, control: true):
                _saveFlashOnly,
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _openFind,
            const SingleActivator(LogicalKeyboardKey.keyH, control: true):
                _openReplace,
            SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
                _applyFormat(MdFormat.bold),
            SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
                _applyFormat(MdFormat.italic),
            SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
                _applyFormat(MdFormat.link),
            const SingleActivator(LogicalKeyboardKey.keyG, control: true):
                _goToLineShortcut,
            const SingleActivator(
              LogicalKeyboardKey.keyD,
              control: true,
              shift: true,
            ): _duplicateLines,
            const SingleActivator(
              LogicalKeyboardKey.keyU,
              control: true,
              shift: true,
            ): _insertToc,
            const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
                _moveLines(up: true),
            const SingleActivator(
              LogicalKeyboardKey.arrowDown,
              alt: true,
            ): () =>
                _moveLines(up: false),
            const SingleActivator(LogicalKeyboardKey.f5): _insertStamp,
          },
          child: Focus(
            autofocus: true,
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Natural height of the fixed content (top bar + card +
                  // toolbar + footer). When the window is at least that
                  // tall, lay out at full height with the footer pinned to
                  // the bottom; when it is shorter, scroll instead. A
                  // Spacer inside a scroll view gets unbounded height and
                  // cannot be laid out, so the two modes are kept separate.
                  // (8 px of slack in the constant covers font-metric
                  // differences between machines, so the full-height
                  // layout is only chosen when it truly fits.)
                  // The open find bar takes height too (about 58 px);
                  // counting it keeps the full-height layout from ever
                  // overflowing when the bar is open.
                  final naturalHeight =
                      348 +
                      _lineHeight * 9 +
                      68 +
                      (_findOpen ? (_replaceMode ? 116 : 58) : 0) +
                      (!_isPreview && _headings.isNotEmpty ? 34 : 0);
                  final column = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _buildTopBar(),
                      const SizedBox(height: 16),
                      _buildCard(),
                      const SizedBox(height: 14),
                      _buildToolbarBar(),
                      const SizedBox(height: 10),
                      _buildFormatBar(),
                      if (_findOpen) ...<Widget>[
                        const SizedBox(height: 10),
                        _buildFindBar(),
                      ],
                    ],
                  );
                  const footer = Text(
                    'autosaves as you type',
                    style: TextStyle(color: kDim, fontSize: 13),
                  );
                  if (constraints.maxHeight >= naturalHeight) {
                    return SizedBox(
                      height: constraints.maxHeight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            column,
                            const Spacer(),
                            const SizedBox(height: 12),
                            footer,
                          ],
                        ),
                      ),
                    );
                  }
                  return SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          column,
                          const SizedBox(height: 12),
                          footer,
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The note's headings with the offset of each heading line, for
  /// the outline strip and go-to-heading jumps.
  List<({String title, int level, int offset})> get _headings {
    final result = <({String title, int level, int offset})>[];
    final lines = _bodyController.text.split('\n');
    var offset = 0;
    final headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
    for (final line in lines) {
      final match = headingRe.firstMatch(line);
      if (match != null) {
        result.add((
          title: match.group(2)!.trim(),
          level: match.group(1)!.length,
          offset: offset,
        ));
      }
      offset += line.length + 1;
    }
    return result;
  }

  /// The outline strip: one small button per heading, in order,
  /// tapping jumps the editor to that heading. Empty when the note
  /// has no headings (the strip takes no space then).
  Widget _buildOutline() {
    final headings = _headings;
    if (headings.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey<String>('outline-strip'),
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          for (final heading in headings)
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: kDim,
                textStyle: TextStyle(
                  fontFamily: kFontFamily,
                  fontFamilyFallback: kFontFallback,
                  fontSize: 13,
                  fontWeight: heading.level <= 2
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 34),
              ),
              onPressed: () {
                _bodyController.selection = TextSelection.collapsed(
                  offset: heading.offset,
                );
                _scrollToOffset(heading.offset);
                _bodyFocus.requestFocus();
              },
              child: Text(
                '${'#' * heading.level} ${heading.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  /// The body area for the current view mode: the raw editor alone,
  /// the editor beside the rendered preview (Split), or the preview
  /// alone.
  Widget _buildBodyArea(TextStyle bodyStyle) {
    switch (_mode) {
      case _ViewMode.preview:
        return MarkdownView(
          key: const ValueKey<String>('markdown-preview'),
          text: _bodyController.text,
          fontSize: _fontSize,
        );
      case _ViewMode.edit:
        return _buildBodyEditor(bodyStyle);
      case _ViewMode.split:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: _buildBodyEditor(bodyStyle)),
            const VerticalDivider(color: Color(0xFF4A4A4A), width: 17),
            Expanded(
              child: MarkdownView(
                key: const ValueKey<String>('markdown-preview'),
                text: _bodyController.text,
                fontSize: _fontSize,
              ),
            ),
          ],
        );
    }
  }

  /// The raw body editor: ruled lines, a line-number gutter that
  /// scrolls with the text, Markdown syntax highlighting (from
  /// [_HighlightController]), and auto-pairing while typing.
  Widget _buildBodyEditor(TextStyle bodyStyle) {
    final lineCount = '\n'.allMatches(_bodyController.text).length + 1;
    final scrollOffset = _bodyScrollController.hasClients
        ? _bodyScrollController.offset
        : 0.0;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: CustomPaint(
            painter: _RuledLinesPainter(
              lineHeight: _lineHeight,
              fontSize: _fontSize,
              color: kRuledLine,
            ),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 34,
          child: CustomPaint(
            painter: _GutterPainter(
              lineCount: lineCount,
              lineHeight: _lineHeight,
              fontSize: _fontSize,
              scrollOffset: scrollOffset,
            ),
          ),
        ),
        Positioned.fill(
          left: 42,
          child: TextField(
            controller: _bodyController,
            focusNode: _bodyFocus,
            scrollController: _bodyScrollController,
            style: bodyStyle,
            cursorColor: kAccent,
            inputFormatters: <TextInputFormatter>[AutoPairFormatter()],
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: 'Write your note',
              hintStyle: TextStyle(color: kDim),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Row(
      children: <Widget>[
        IconButton(
          tooltip: 'Back (Esc)',
          icon: const Icon(Icons.arrow_back, size: 26),
          onPressed: _requestClose,
        ),
        const Spacer(),
        SizedBox(
          width: _savedFlash ? 92 : 52,
          height: 48,
          child: ElevatedButton(
            style: primaryButtonStyle(),
            onPressed: _checkAndPop,
            child: _savedFlash
                ? const Text('Saved', style: TextStyle(fontSize: 14))
                : const Icon(Icons.check, size: 24),
          ),
        ),
      ],
    );
  }

  Widget _buildCard() {
    final bodyStyle = TextStyle(
      color: Colors.white,
      fontSize: _fontSize,
      height: _lineFactor,
    );
    return Container(
      decoration: cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              controller: _titleController,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              cursorColor: kAccent,
              decoration: const InputDecoration(
                hintText: 'Title',
                hintStyle: TextStyle(color: kDim),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (_) => _scheduleSave(),
            ),
            const Divider(color: Color(0xFF4A4A4A), height: 22),
            TextField(
              controller: _tagsController,
              style: const TextStyle(color: Color(0xFFC9C9C9), fontSize: 14),
              cursorColor: kAccent,
              decoration: const InputDecoration(
                hintText: 'Tags, separated by commas',
                hintStyle: TextStyle(color: kDim),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onChanged: (_) => _scheduleSave(),
            ),
            const Divider(color: Color(0xFF4A4A4A), height: 22),
            if (_mode != _ViewMode.preview) _buildOutline(),
            SizedBox(height: _lineHeight * 9, child: _buildBodyArea(bodyStyle)),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _countLabel,
                style: const TextStyle(color: kDim, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarBar() {
    final textButton = TextButton.styleFrom(
      foregroundColor: Colors.white,
      textStyle: const TextStyle(
        fontFamily: kFontFamily,
        fontFamilyFallback: kFontFallback,
        fontSize: 15,
        fontWeight: FontWeight.bold,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    );
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          TextButton(
            style: textButton,
            onPressed: () => _changeSize(-1),
            child: const Tooltip(
              message: 'Make the text smaller',
              child: Text('A-'),
            ),
          ),
          TextButton(
            style: textButton,
            onPressed: () => _changeSize(1),
            child: const Tooltip(
              message: 'Make the text bigger',
              child: Text('A+'),
            ),
          ),
          TextButton(
            style: textButton,
            onPressed: () => _convertBody(numbered: true),
            child: const Tooltip(
              message:
                  'Convert to a numbered list '
                  '(again to remove the numbers)',
              child: Text('1.'),
            ),
          ),
          TextButton(
            style: textButton,
            onPressed: () => _convertBody(numbered: false),
            child: const Tooltip(
              message:
                  'Convert to a bullet list '
                  '(again to remove the bullets)',
              child: Text('•'),
            ),
          ),
          TextButton(
            style: textButton.copyWith(
              foregroundColor: WidgetStateProperty.all(
                _note.pinned ? kAccentText : Colors.white,
              ),
            ),
            onPressed: _togglePin,
            child: Tooltip(
              message: _note.pinned
                  ? 'Unpin this note'
                  : 'Pin this note to the top of the list',
              child: Text(
                'PIN',
                style: TextStyle(
                  color: _note.pinned ? kAccentText : Colors.white,
                ),
              ),
            ),
          ),
          TextButton(
            style: textButton,
            onPressed: _duplicate,
            child: const Tooltip(
              message: 'Copy this note',
              child: Text('COPY'),
            ),
          ),
          TextButton(
            style: textButton,
            onPressed: () => unawaited(_showFileInExplorer()),
            child: const Tooltip(
              message: "Show this note's file in Explorer",
              child: Text('FILE'),
            ),
          ),
          TextButton(
            style: textButton,
            onPressed: _delete,
            child: const Tooltip(
              message: 'Move this note to the trash',
              child: Text('DELETE'),
            ),
          ),
        ],
      ),
    );
  }

  /// The Markdown bar: the Edit / Preview switch plus the formatting
  /// buttons. Formatting buttons act on the selected body text (see
  /// [_applyFormat]) and are off while the preview is showing.
  Widget _buildFormatBar() {
    TextButton modeButton(String label, bool active, VoidCallback onTap) {
      return TextButton(
        style: TextButton.styleFrom(
          foregroundColor: active ? kAccentText : Colors.white,
          textStyle: const TextStyle(
            fontFamily: kFontFamily,
            fontFamilyFallback: kFontFallback,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        ),
        onPressed: onTap,
        child: Text(label),
      );
    }

    Widget formatButton(
      String label,
      String tooltip,
      MdFormat format, {
      bool italic = false,
      bool strike = false,
    }) {
      return TextButton(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          textStyle: TextStyle(
            fontFamily: kFontFamily,
            fontFamilyFallback: kFontFallback,
            fontSize: 15,
            fontWeight: FontWeight.bold,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            decoration: strike
                ? TextDecoration.lineThrough
                : TextDecoration.none,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        ),
        onPressed: _isPreview ? null : () => _applyFormat(format),
        child: Tooltip(message: tooltip, child: Text(label)),
      );
    }

    return Container(
      key: const ValueKey<String>('format-bar'),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      // The bar scrolls sideways on a narrow window instead of
      // overflowing: there are more buttons than the minimum width
      // always fits.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            modeButton(
              'EDIT',
              _mode == _ViewMode.edit,
              () => _setMode(_ViewMode.edit),
            ),
            modeButton(
              'SPLIT',
              _mode == _ViewMode.split,
              () => _setMode(_ViewMode.split),
            ),
            modeButton(
              'PREVIEW',
              _mode == _ViewMode.preview,
              () => _setMode(_ViewMode.preview),
            ),
            const Text('|', style: TextStyle(color: kDim, fontSize: 15)),
            formatButton(
              'B',
              'Bold the selected text (Ctrl+B; again to undo)',
              MdFormat.bold,
            ),
            formatButton(
              'I',
              'Italic the selected text (Ctrl+I; again to undo)',
              MdFormat.italic,
              italic: true,
            ),
            formatButton(
              'S',
              'Strike through the selected text (again to undo)',
              MdFormat.strike,
              strike: true,
            ),
            formatButton(
              'H',
              'Heading level: each press goes one deeper (#, ##, ###), then back to plain',
              MdFormat.heading,
            ),
            formatButton(
              '</>',
              'Make the selected text code (a fenced block for several lines)',
              MdFormat.code,
            ),
            formatButton(
              'LINK',
              'Make the selected text a link (again to undo)',
              MdFormat.link,
            ),
            formatButton(
              '>',
              'Quote the selected lines (again to undo)',
              MdFormat.quote,
            ),
            formatButton(
              '☑',
              'Make the selected lines a checklist (again to undo)',
              MdFormat.checklist,
            ),
          ],
        ),
      ),
    );
  }

  /// The find bar: a slim row under the toolbar with the query field,
  /// the match count in plain words, previous/next buttons, and a
  /// close button. Enter steps to the next match, Shift+Enter to the
  /// previous one (the field's submit action reports both; the shift
  /// state tells them apart), and Esc closes the bar (see
  /// [_handleEscape]).
  Widget _buildFindBar() {
    final hasMatches = _findMatches.isNotEmpty;
    return Container(
      key: const ValueKey<String>('find-bar'),
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kBorder),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.search, size: 20, color: kDim),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('find-field'),
                  controller: _findController,
                  focusNode: _findFocus,
                  autofocus: true,
                  // An explicit action makes Enter submit (and so step
                  // to the next match) on every platform; without it a
                  // single-line field may treat Enter as a newline
                  // request and never call onSubmitted.
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  cursorColor: kAccent,
                  decoration: const InputDecoration(
                    hintText: 'Find in this note',
                    hintStyle: TextStyle(color: kDim),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onSubmitted: (_) {
                    if (HardwareKeyboard.instance.isShiftPressed) {
                      _findStep(-1);
                    } else {
                      _findStep(1);
                    }
                  },
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: _findRegex ? kAccentText : kDim,
                  textStyle: const TextStyle(
                    fontFamily: kFontFamily,
                    fontFamilyFallback: kFontFallback,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 36),
                ),
                onPressed: () {
                  setState(() => _findRegex = !_findRegex);
                  _refreshFindMatches(resetCurrent: true);
                  if (_findCurrent >= 0) _selectFindMatch();
                },
                child: const Tooltip(
                  message:
                      'Treat the search words as a pattern (regular expression)',
                  child: Text('.*'),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                _findStatus,
                style: const TextStyle(color: kDim, fontSize: 13),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Previous match',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_arrow_up, size: 22),
                onPressed: hasMatches ? () => _findStep(-1) : null,
              ),
              IconButton(
                tooltip: 'Next match',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.keyboard_arrow_down, size: 22),
                onPressed: hasMatches ? () => _findStep(1) : null,
              ),
              IconButton(
                tooltip: _replaceMode ? 'Hide replace' : 'Find and replace',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.find_replace, size: 20),
                onPressed: () => setState(() => _replaceMode = !_replaceMode),
              ),
              IconButton(
                tooltip: 'Close find',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 20),
                onPressed: _closeFind,
              ),
            ],
          ),
          if (_replaceMode)
            Row(
              children: <Widget>[
                const Icon(Icons.edit, size: 18, color: kDim),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('replace-field'),
                    controller: _replaceController,
                    style: const TextStyle(color: Colors.white, fontSize: 15),
                    cursorColor: kAccent,
                    decoration: const InputDecoration(
                      hintText: 'Replace with',
                      hintStyle: TextStyle(color: kDim),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: hasMatches ? _replaceCurrent : null,
                  child: const Text('Replace'),
                ),
                TextButton(
                  onPressed: hasMatches ? _replaceAll : null,
                  child: const Text('Replace all'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Paints the editor's ruled lines: one faint line under each text line,
/// continuing down the whole body area like the phone app's notepaper.
/// Everything is derived from [lineHeight] and [fontSize], so the lines
/// stay under the text at every text size.
class _RuledLinesPainter extends CustomPainter {
  const _RuledLinesPainter({
    required this.lineHeight,
    required this.fontSize,
    required this.color,
  });

  final double lineHeight;
  final double fontSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    // The first line sits just under the first line of text: one line
    // box down, minus the descender gap under the glyphs.
    var y = lineHeight - fontSize * 0.34;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      y += lineHeight;
    }
  }

  @override
  bool shouldRepaint(_RuledLinesPainter oldDelegate) {
    return oldDelegate.lineHeight != lineHeight ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.color != color;
  }
}

/// Paints the line-number gutter: one dim number per text line,
/// aligned with the ruled lines and scrolled by the same offset as
/// the body field, so a number always sits beside its line.
class _GutterPainter extends CustomPainter {
  const _GutterPainter({
    required this.lineCount,
    required this.lineHeight,
    required this.fontSize,
    required this.scrollOffset,
  });

  final int lineCount;
  final double lineHeight;
  final double fontSize;
  final double scrollOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFF161616);
    canvas.drawRect(Offset.zero & size, background);
    final firstLine = (scrollOffset / lineHeight).floor();
    for (var line = firstLine; line < lineCount; line++) {
      final y = line * lineHeight - scrollOffset;
      if (y > size.height) break;
      final painter = TextPainter(
        text: TextSpan(
          text: '${line + 1}',
          style: TextStyle(color: kDim, fontSize: fontSize - 3),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
      )..layout(maxWidth: size.width - 6);
      painter.paint(canvas, Offset(size.width - 6 - painter.width, y + 2));
    }
  }

  @override
  bool shouldRepaint(_GutterPainter oldDelegate) {
    return oldDelegate.lineCount != lineCount ||
        oldDelegate.lineHeight != lineHeight ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.scrollOffset != scrollOffset;
  }
}

/// A body controller that paints Markdown syntax highlighting over
/// the raw text, Ferrite-style, while keeping TermiNote's palette:
/// the words stay white; the marks (`#`, `**`, backticks) and links
/// take the red accent, quotes and list marks go dim, headings are
/// bold, and code takes a lighter red. Highlighting is line-based and
/// forgiving — an unclosed mark simply stays plain.
class _HighlightController extends TextEditingController {
  _HighlightController({super.text});

  static final RegExp _headingRe = RegExp(r'^(#{1,6}\s+)(.*)$');
  static final RegExp _inlineRe = RegExp(
    r'(\*\*.+?\*\*|~~.+?~~|\*[^*\n]+?\*|`[^`\n]+?`|\[[^\]\n]*\]\([^)\n]*\))',
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final spans = <TextSpan>[];
    var inFence = false;
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isLast = i == lines.length - 1;
      void add(String chunk, TextStyle chunkStyle) {
        if (chunk.isNotEmpty)
          spans.add(TextSpan(text: chunk, style: chunkStyle));
      }

      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        add(line, base.copyWith(color: kAccentText));
      } else if (inFence) {
        add(line, base.copyWith(color: const Color(0xFFFFB3BA)));
      } else {
        final heading = _headingRe.firstMatch(line);
        if (heading != null) {
          add(heading.group(1)!, base.copyWith(color: kAccentText));
          add(heading.group(2)!, base.copyWith(fontWeight: FontWeight.bold));
        } else if (line.trimLeft().startsWith('>')) {
          add(line, base.copyWith(color: kDim, fontStyle: FontStyle.italic));
        } else {
          var at = 0;
          for (final match in _inlineRe.allMatches(line)) {
            if (match.start > at) add(line.substring(at, match.start), base);
            final token = match.group(0)!;
            if (token.startsWith('**')) {
              add(token, base.copyWith(fontWeight: FontWeight.bold));
            } else if (token.startsWith('~~')) {
              add(token, base.copyWith(decoration: TextDecoration.lineThrough));
            } else if (token.startsWith('`')) {
              add(token, base.copyWith(color: kAccentText));
            } else if (token.startsWith('[')) {
              add(token, base.copyWith(color: kAccentText));
            } else {
              add(token, base.copyWith(fontStyle: FontStyle.italic));
            }
            at = match.end;
          }
          if (at < line.length) add(line.substring(at), base);
        }
      }
      if (!isLast) add('\n', base);
    }
    return TextSpan(style: base, children: spans);
  }
}
