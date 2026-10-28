/// TermiNote: entry point, shared app state, and the note list screen.
///
/// With command-line arguments the program runs as a CLI (see cli.dart)
/// and never opens a window. With no arguments it opens the list screen:
/// a phone-app layout in a desktop window — a centered column, a header
/// with a blinking terminal cursor, a toolbar, tag chips, and note cards
/// that show TITLES ONLY. Body text never appears on this screen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cli.dart';
import 'editor_screen.dart';
import 'note_store.dart';
import 'settings_screen.dart';
import 'theme.dart';

Future<void> main(List<String> args) async {
  if (isCliArgs(args)) {
    io.exitCode = await runCli(args);
    return;
  }
  runApp(TermiNoteApp(state: AppState.load()));
}

/// Everything the screens share: the store, where it lives on disk, the
/// display settings, and the last-saved time. Screens call [persist]
/// after any change; it writes the file and tells listeners to redraw.
class AppState extends ChangeNotifier {
  AppState({
    required this.store,
    required this.dataPath,
    this.sortMode = SortMode.modifiedDesc,
    this.textSize = 16,
  });

  /// Loads the store and the settings from their normal locations.
  factory AppState.load() {
    final path = StoreFile.resolvePath();
    final store = StoreFile.load(path);
    var sort = SortMode.modifiedDesc;
    var size = 16.0;
    try {
      final settingsFile = io.File(settingsPathFor(path));
      if (settingsFile.existsSync()) {
        final decoded = jsonDecode(settingsFile.readAsStringSync());
        if (decoded is Map) {
          sort = sortModeFromName(decoded['sort']?.toString());
          final rawSize = decoded['textSize'];
          if (rawSize is num) size = rawSize.toDouble().clamp(12, 28);
        }
      }
    } on Exception {
      // Settings are a nicety; broken settings must never block startup.
    }
    return AppState(
      store: store,
      dataPath: path,
      sortMode: sort,
      textSize: size,
    );
  }

  /// The notebook itself.
  final NoteStore store;

  /// Full path of the notes data file.
  final String dataPath;

  /// Current list sort order (persisted in the settings file).
  SortMode sortMode;

  /// Editor text size in points (persisted in the settings file).
  double textSize;

  /// When the notes file was last written this session, if ever.
  DateTime? lastSavedAt;

  /// The settings file sits beside the data file.
  static String settingsPathFor(String dataPath) {
    final cut = dataPath.lastIndexOf(RegExp(r'[\\/]'));
    if (cut < 0) return 'terminote-settings.json';
    return '${dataPath.substring(0, cut + 1)}settings.json';
  }

  /// Writes the settings file (sort order + text size).
  void saveSettings() {
    try {
      final file = io.File(settingsPathFor(dataPath));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'sort': sortMode.name,
          'textSize': textSize,
        }),
      );
    } on Exception {
      // Failing to remember a setting is not worth an error dialog.
    }
  }

  /// Writes the notes file, stamps the saved time, and notifies.
  void persist() {
    StoreFile.save(dataPath, store);
    lastSavedAt = DateTime.now();
    notifyListeners();
  }

  /// Notifies without writing (display-only changes).
  void refresh() => notifyListeners();
}

/// The application widget. Tests hand it a ready-made [AppState].
class TermiNoteApp extends StatelessWidget {
  const TermiNoteApp({super.key, required this.state});

  /// Shared state for the whole app.
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermiNote',
      debugShowCheckedModeBanner: false,
      theme: buildTermiNoteTheme(),
      home: ListScreen(state: state),
    );
  }
}

/// The note list screen (the app's home).
class ListScreen extends StatefulWidget {
  const ListScreen({super.key, required this.state});

  /// Shared app state.
  final AppState state;

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _shortcutFocus = FocusNode();

  String? _tagFilter; // null + !_untagged == "All notes"
  bool _untagged = false;
  bool _searchOpen = false;
  String _query = '';

  AppState get state => widget.state;
  NoteStore get store => widget.state.store;

  @override
  void initState() {
    super.initState();
    state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    state.removeListener(_onStateChanged);
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _shortcutFocus.dispose();
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  List<Note> get _visible => store.list(
    search: _query,
    tag: _tagFilter,
    untagged: _untagged,
    sort: state.sortMode,
  );

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() {
      _searchOpen = false;
      _query = '';
      _searchController.clear();
    });
    _shortcutFocus.requestFocus();
  }

  Future<void> _openEditor(Note? note) async {
    final result = await Navigator.of(
      context,
    ).push<String>(phoneRoute(EditorScreen(state: state, note: note)));
    if (!mounted) return;
    if (result == 'deleted') {
      _showUndoSnack('Note deleted.', () {
        final trashed = store.trash;
        if (trashed.isNotEmpty) store.restore(trashed.last.id);
      });
    }
    setState(() {});
  }

  void _deleteNote(Note note) {
    store.delete(note.id);
    state.persist();
    _showUndoSnack('Note deleted.', () => store.restore(note.id));
  }

  void _showUndoSnack(String message, void Function() undo) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'UNDO',
          textColor: kAccentText,
          onPressed: () {
            undo();
            state.persist();
          },
        ),
      ),
    );
  }

  Future<void> _deleteAll() async {
    if (store.notes.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Delete all notes?'),
        content: const Text(
          'This moves every note to the trash. You can undo it straight '
          'away, or bring notes back later from Settings, in the Trash '
          'list.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: primaryButtonStyle(),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ids = store.notes.map((n) => n.id).toList();
    store.deleteAll();
    state.persist();
    _showUndoSnack('All notes deleted.', () {
      for (final id in ids) {
        store.restore(id);
      }
    });
  }

  void _setSort(SortMode mode) {
    state.sortMode = mode;
    state.saveSettings();
    setState(() {});
  }

  void _onReorder(int oldIndex, int newIndex, List<Note> visible) {
    // onReorderItem reports newIndex as the final position already.
    final target = newIndex;
    final ids = visible.map((n) => n.id).toList();
    final moved = ids.removeAt(oldIndex);
    ids.insert(target, moved);
    // Keep non-visible notes in their previous relative order behind the
    // reordered visible ones.
    final rest = store
        .list(sort: SortMode.manual)
        .map((n) => n.id)
        .where((id) => !ids.contains(id));
    store.reorder(<int>[...ids, ...rest]);
    state.sortMode = SortMode.manual;
    state.saveSettings();
    state.persist();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final stats = store.stats();
    return Scaffold(
      body: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              _openEditor(null),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              _openSearch,
        },
        child: Focus(
          focusNode: _shortcutFocus,
          autofocus: true,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kColumnWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _buildHeader(),
                    const SizedBox(height: 18),
                    _buildToolbar(),
                    const SizedBox(height: 14),
                    _buildChips(),
                    const SizedBox(height: 14),
                    Expanded(child: _buildListArea(visible)),
                    const SizedBox(height: 8),
                    _buildStatusBar(stats),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: <Widget>[
        const Text(
          '> TermiNote',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 14),
        const _BlinkingCursor(),
        const Spacer(),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings, size: 30),
          onPressed: () async {
            await Navigator.of(
              context,
            ).push<String>(phoneRoute(SettingsScreen(state: state)));
            if (mounted) setState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    final collapsed = Row(
      key: const ValueKey<String>('toolbar-collapsed'),
      children: <Widget>[
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: 'Search notes (Ctrl+F)',
            style: darkIconButtonStyle(),
            icon: const Icon(Icons.search),
            onPressed: _openSearch,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              style: primaryButtonStyle(),
              icon: const Icon(Icons.edit_note, size: 22),
              label: const Text('Add note'),
              onPressed: () => _openEditor(null),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            style: darkButtonStyle(),
            onPressed: _deleteAll,
            child: const Text('All Delete'),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 48,
          height: 48,
          child: PopupMenuButton<SortMode>(
            tooltip: 'Sort notes',
            color: kSurface,
            initialValue: state.sortMode,
            onSelected: _setSort,
            itemBuilder: (context) => const <PopupMenuEntry<SortMode>>[
              PopupMenuItem<SortMode>(
                value: SortMode.modifiedDesc,
                child: Text('Newest changed first'),
              ),
              PopupMenuItem<SortMode>(
                value: SortMode.titleAsc,
                child: Text('Title A to Z'),
              ),
              PopupMenuItem<SortMode>(
                value: SortMode.createdDesc,
                child: Text('Newest created first'),
              ),
              PopupMenuItem<SortMode>(
                value: SortMode.manual,
                child: Text('My drag order'),
              ),
            ],
            child: Container(
              decoration: BoxDecoration(
                color: kSurfaceAlt,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.sort, color: Colors.white),
            ),
          ),
        ),
      ],
    );
    final expanded = Row(
      key: const ValueKey<String>('toolbar-search'),
      children: <Widget>[
        Expanded(
          child: SizedBox(
            height: 48,
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocus,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              cursorColor: kAccent,
              decoration: InputDecoration(
                hintText: 'Search titles, tags, text',
                hintStyle: const TextStyle(color: kDim),
                prefixIcon: const Icon(Icons.search, color: kDim),
                suffixIcon: IconButton(
                  tooltip: 'Close search (Esc)',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: _closeSearch,
                ),
                filled: true,
                fillColor: kSurfaceAlt,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: kAccent, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onChanged: (value) => setState(() => _query = value),
              onSubmitted: (_) => _shortcutFocus.requestFocus(),
            ),
          ),
        ),
      ],
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchOpen) _closeSearch();
        },
      },
      child: AnimatedCrossFade(
        duration: const Duration(milliseconds: 220),
        crossFadeState: _searchOpen
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        firstChild: collapsed,
        secondChild: expanded,
      ),
    );
  }

  Widget _buildChips() {
    final chips = <Widget>[
      _TagChip(
        label: 'All notes',
        selected: _tagFilter == null && !_untagged,
        onTap: () => setState(() {
          _tagFilter = null;
          _untagged = false;
        }),
      ),
      _TagChip(
        label: 'Untagged',
        selected: _untagged,
        onTap: () => setState(() {
          _tagFilter = null;
          _untagged = true;
        }),
      ),
      for (final entry in store.allTags())
        _TagChip(
          label: entry.key,
          selected: _tagFilter == entry.key,
          onTap: () => setState(() {
            _tagFilter = entry.key;
            _untagged = false;
          }),
        ),
    ];
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) => chips[index],
      ),
    );
  }

  Widget _buildListArea(List<Note> visible) {
    if (store.notes.isEmpty) {
      return const _EmptyState(
        headline: '> no notes yet',
        line: 'Press Add note to write your first one.',
      );
    }
    if (visible.isEmpty) {
      return const _EmptyState(
        headline: '> nothing matches',
        line: 'Try a different tag, or clear the search.',
      );
    }
    return Scrollbar(
      controller: _scrollController,
      child: ReorderableListView.builder(
        scrollController: _scrollController,
        buildDefaultDragHandles: false,
        itemCount: visible.length,
        onReorderItem: (oldIndex, newIndex) =>
            _onReorder(oldIndex, newIndex, visible),
        proxyDecorator: (child, index, animation) {
          return Material(
            color: Colors.transparent,
            elevation: 6,
            shadowColor: Colors.black,
            borderRadius: BorderRadius.circular(14),
            child: child,
          );
        },
        itemBuilder: (context, index) {
          final note = visible[index];
          return _NoteCard(
            key: ValueKey<int>(note.id),
            note: note,
            index: index,
            onOpen: () => _openEditor(note),
            onEdit: () => _openEditor(note),
            onDelete: () => _deleteNote(note),
          );
        },
      ),
    );
  }

  Widget _buildStatusBar(StoreStats stats) {
    final saved = state.lastSavedAt;
    return Row(
      children: <Widget>[
        Text(
          '${stats.notes} notes · ${stats.tags} tags · ${stats.pinned} pinned',
          style: const TextStyle(color: kDim, fontSize: 13),
        ),
        const Spacer(),
        Text(
          saved == null ? '' : 'saved ${formatClock(saved)}',
          style: const TextStyle(color: kDim, fontSize: 13),
        ),
      ],
    );
  }
}

/// The solid red block cursor after the header title, blinking with a
/// steady terminal rhythm (about one second on, then off).
class _BlinkingCursor extends StatefulWidget {
  const _BlinkingCursor();

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1060),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final on = _controller.value < 0.55;
        return Container(
          width: 17,
          height: 26,
          color: on ? kAccent : Colors.transparent,
        );
      },
    );
  }
}

/// One filter chip in the tag row. Selection animates, it never snaps.
class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected ? kAccent : kSurface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: selected ? kAccent : const Color(0xFF555555)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One note card: timestamp row, TITLE ONLY, tag chips. Never body text.
class _NoteCard extends StatefulWidget {
  const _NoteCard({
    super.key,
    required this.note,
    required this.index,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  final Note note;
  final int index;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<_NoteCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final note = widget.note;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hovered ? -2 : 0, 0),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: _hovered ? kAccent.withValues(alpha: 0.55) : kBorder,
          ),
          boxShadow: _hovered
              ? const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.schedule, size: 16, color: kDim),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          formatStamp(note.modified),
                          style: const TextStyle(color: kDim, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit note',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit, size: 19),
                        onPressed: widget.onEdit,
                      ),
                      IconButton(
                        tooltip: 'Delete note',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete, size: 19),
                        onPressed: widget.onDelete,
                      ),
                      ReorderableDragStartListener(
                        index: widget.index,
                        child: Tooltip(
                          message: 'Drag to reorder',
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(
                              Icons.drag_handle,
                              size: 19,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (note.pinned) ...<Widget>[
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          width: 9,
                          height: 9,
                          decoration: const BoxDecoration(
                            color: kAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 9),
                      ],
                      Expanded(
                        child: Text(
                          note.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (note.tags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final tag in note.tags)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: kTagChip,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Centered empty-state text, in terminal voice.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.headline, required this.line});

  final String headline;
  final String line;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            headline,
            style: const TextStyle(
              color: kDim,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Text(line, style: const TextStyle(color: kDim, fontSize: 14)),
        ],
      ),
    );
  }
}
