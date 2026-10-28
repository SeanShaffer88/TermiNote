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
import 'main.dart';
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
  List<int> _findMatches = <int>[];
  int _findCurrent = -1;

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
    _bodyController = TextEditingController(text: _note.body);
    _findController = TextEditingController();
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
  /// otherwise it is kept where it was, clamped into range.
  void _refreshFindMatches({required bool resetCurrent}) {
    final query = _findController.text;
    final body = _bodyController.text;
    final found = <int>[];
    if (query.isNotEmpty) {
      final haystack = body.toLowerCase();
      final needle = query.toLowerCase();
      var from = 0;
      while (from + needle.length <= haystack.length) {
        final hit = haystack.indexOf(needle, from);
        if (hit < 0) break;
        found.add(hit);
        from = hit + needle.length;
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
    final start = _findMatches[_findCurrent];
    _bodyController.selection = TextSelection(
      baseOffset: start,
      extentOffset: start + _findController.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_bodyScrollController.hasClients) return;
      final before = _bodyController.text.substring(0, start);
      final line = '\n'.allMatches(before).length;
      final maxExtent = _bodyScrollController.position.maxScrollExtent;
      final target = (line * _lineHeight - _lineHeight).clamp(0.0, maxExtent);
      _bodyScrollController.jumpTo(target);
    });
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

  /// The words-and-characters line under the editor card.
  String get _countLabel {
    final text = _bodyController.text;
    final words = text.trim().isEmpty
        ? 0
        : RegExp(r'\S+').allMatches(text).length;
    final chars = text.length;
    return '$words ${words == 1 ? 'word' : 'words'} · '
        '$chars ${chars == 1 ? 'character' : 'characters'}';
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
                      348 + _lineHeight * 9 + (_findOpen ? 58 : 0);
                  final column = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _buildTopBar(),
                      const SizedBox(height: 16),
                      _buildCard(),
                      const SizedBox(height: 14),
                      _buildToolbarBar(),
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
            SizedBox(
              height: _lineHeight * 9,
              child: Stack(
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
                  TextField(
                    controller: _bodyController,
                    focusNode: _bodyFocus,
                    scrollController: _bodyScrollController,
                    style: bodyStyle,
                    cursorColor: kAccent,
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
                ],
              ),
            ),
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
      child: Row(
        children: <Widget>[
          const Icon(Icons.search, size: 20, color: kDim),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey<String>('find-field'),
              controller: _findController,
              focusNode: _findFocus,
              autofocus: true,
              // An explicit action makes Enter submit (and so step to
              // the next match) on every platform; without it a
              // single-line field may treat Enter as a newline request
              // and never call onSubmitted.
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
          const SizedBox(width: 8),
          Text(_findStatus, style: const TextStyle(color: kDim, fontSize: 13)),
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
            tooltip: 'Close find',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 20),
            onPressed: _closeFind,
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
