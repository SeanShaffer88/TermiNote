/// The note editor page, pushed over the list like the phone app.
///
/// One big card: title, divider, tags, divider, then the body on faint
/// ruled lines that stay aligned to the text at every size. Changes save
/// automatically as you type (about 600 ms after the last keystroke);
/// the red check button saves, flashes "Saved", and goes back.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';
import 'note_store.dart';
import 'theme.dart';

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
  late double _fontSize;
  Timer? _debounce;
  bool _savedFlash = false;
  bool _isNew = false;

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
      state.persist();
    } else {
      _note = widget.note!;
    }
    // A brand-new note opens with an empty title field (the store calls it
    // "Untitled note" as a placeholder until the user types one).
    _titleController = TextEditingController(text: _isNew ? '' : _note.title);
    _tagsController = TextEditingController(text: _note.tags.join(', '));
    _bodyController = TextEditingController(text: _note.body);
    _fontSize = state.textSize;
    _bodyController.addListener(_onBodyChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _flush();
    _titleController.dispose();
    _tagsController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _onBodyChanged() {
    if (mounted) setState(() {});
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _flush);
  }

  /// Writes the field contents into the store and saves the file. A new
  /// note the user left completely empty is removed again instead of
  /// cluttering the list with a blank "Untitled note".
  void _flush() {
    if (_isNew &&
        _titleController.text.trim().isEmpty &&
        _bodyController.text.trim().isEmpty) {
      store.delete(_note.id);
      store.deleteForever(_note.id);
      state.persist();
      _isNew = false; // it is gone either way now
      return;
    }
    store.update(
      _note.id,
      title: _titleController.text,
      body: _bodyController.text,
      tags: parseTags(_tagsController.text),
      now: nowSeconds(),
    );
    state.persist();
  }

  Future<void> _checkAndPop() async {
    _debounce?.cancel();
    _flush();
    if (!mounted) return;
    setState(() => _savedFlash = true);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (mounted) Navigator.of(context).pop('saved');
  }

  void _saveFlashOnly() {
    _debounce?.cancel();
    _flush();
    setState(() => _savedFlash = true);
    Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _savedFlash = false);
    });
  }

  void _changeSize(double delta) {
    setState(() {
      _fontSize = (_fontSize + delta).clamp(12, 28);
    });
    state.textSize = _fontSize;
    state.saveSettings();
  }

  void _togglePin() {
    store.setPinned(_note.id, pinned: !_note.pinned, now: nowSeconds());
    state.persist();
    setState(() {});
  }

  void _duplicate() {
    _flush();
    final copy = store.duplicate(_note.id, now: nowSeconds());
    state.persist();
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

  void _delete() {
    _debounce?.cancel();
    final untouchedNew =
        _isNew &&
        _titleController.text.trim().isEmpty &&
        _bodyController.text.trim().isEmpty;
    _flush();
    if (untouchedNew) {
      // _flush already discarded the blank new note; there is nothing in
      // the trash to undo, so just go back.
      Navigator.of(context).pop('saved');
      return;
    }
    store.delete(_note.id);
    state.persist();
    Navigator.of(context).pop('deleted');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () {
            _debounce?.cancel();
            _flush();
            Navigator.of(context).pop('saved');
          },
          const SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _saveFlashOnly,
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
                final naturalHeight = 340 + _lineHeight * 9;
                final column = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _buildTopBar(),
                    const SizedBox(height: 16),
                    _buildCard(),
                    const SizedBox(height: 14),
                    _buildToolbarBar(),
                  ],
                );
                const footer = Text(
                  'autosaves as you type',
                  style: TextStyle(color: kDim, fontSize: 13),
                );
                if (constraints.maxHeight >= naturalHeight) {
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: kColumnWidth),
                      child: SizedBox(
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
                      ),
                    ),
                  );
                }
                return SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: kColumnWidth),
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
                    ),
                  ),
                );
              },
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
          onPressed: () {
            _debounce?.cancel();
            _flush();
            Navigator.of(context).pop('saved');
          },
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
      decoration: BoxDecoration(
        color: kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
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
                '${_bodyController.text.length}',
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
