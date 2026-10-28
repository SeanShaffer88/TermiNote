/// TermiNote: entry point, shared app state, and the note list screen.
///
/// With command-line arguments the program runs as a CLI (see cli.dart)
/// and never opens a window. With no arguments it opens the list screen:
/// a phone-app layout in a desktop window that fills the full window
/// width — a header with a blinking terminal cursor, a toolbar, tag
/// chips, and note cards that show TITLES ONLY. Body text never appears
/// on this screen.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cli.dart';
import 'editor_screen.dart';
import 'note_store.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'window_channel.dart';

Future<void> main(List<String> args) async {
  if (isCliArgs(args)) {
    io.exitCode = await runCli(args);
    return;
  }
  runApp(TermiNoteApp(state: await AppState.load()));
}

/// Everything the screens share: the store, where it lives on disk, the
/// display settings, and the last-saved time. Screens call [persist]
/// after any change; it writes the changed note files (asynchronously —
/// the window never waits on the disk) and tells listeners to redraw.
class AppState extends ChangeNotifier {
  AppState({
    required this.store,
    required this.dataDir,
    this.sortMode = SortMode.modifiedDesc,
    this.textSize = 16,
    this.minimizeToTray = true,
  });

  /// Loads the store and the settings from their normal locations.
  /// Fully asynchronous, including the one-time conversion of an old
  /// `notes.json` when [StoreFile.load] finds one.
  static Future<AppState> load() async {
    final dataDir = StoreFile.resolveDataDir();
    final store = await StoreFile.load(dataDir);
    var sort = SortMode.modifiedDesc;
    var size = 16.0;
    var tray = true;
    try {
      final decoded = jsonDecode(
        await io.File(settingsPathFor(dataDir)).readAsString(),
      );
      if (decoded is Map) {
        sort = sortModeFromName(decoded['sort']?.toString());
        final rawSize = decoded['textSize'];
        if (rawSize is num) size = rawSize.toDouble().clamp(12, 28);
        final rawTray = decoded['minimize_to_tray'];
        if (rawTray is bool) tray = rawTray;
      }
    } on Exception {
      // Settings are a nicety; broken or missing settings must never
      // block startup.
    }
    return AppState(
      store: store,
      dataDir: dataDir,
      sortMode: sort,
      textSize: size,
      minimizeToTray: tray,
    );
  }

  /// The notebook itself.
  final NoteStore store;

  /// Full path of the data directory (holds `settings.json` and the
  /// `notes` folder).
  final String dataDir;

  /// Full path of the folder holding the note files.
  String get notesDir => StoreFile.notesDirFor(dataDir);

  /// Current list sort order (persisted in the settings file).
  SortMode sortMode;

  /// Editor text size in points (persisted in the settings file).
  double textSize;

  /// Whether minimizing the window tucks the program into the system
  /// tray instead of the taskbar (persisted in the settings file).
  bool minimizeToTray;

  /// When the note files were last written this session, if ever.
  DateTime? lastSavedAt;

  /// The settings file sits in the data directory.
  static String settingsPathFor(String dataDir) =>
      '$dataDir${io.Platform.pathSeparator}settings.json';

  /// Writes the settings file (sort order + text size + tray setting).
  Future<void> saveSettings() async {
    try {
      final file = io.File(settingsPathFor(dataDir));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'sort': sortMode.name,
          'textSize': textSize,
          'minimize_to_tray': minimizeToTray,
        }),
      );
    } on Exception {
      // Failing to remember a setting is not worth an error dialog.
    }
  }

  /// Writes whichever note files changed, stamps the saved time, and
  /// notifies. The write itself is asynchronous; the in-memory store
  /// the screens read from is already up to date, so nothing waits.
  Future<void> persist() async {
    await store.saveDirty();
    lastSavedAt = DateTime.now();
    notifyListeners();
  }

  /// Notifies without writing (display-only changes).
  void refresh() => notifyListeners();

  // -- Unsaved-work registry -------------------------------------------
  // The editor autosaves on a short delay, so at any moment it may hold
  // changes that are not on disk yet. While an editor is open it
  // registers itself here, so the program-close check in [TermiNoteApp]
  // can ask before quitting instead of silently losing those keystrokes.

  /// Whether the open editor (if any) holds changes not yet saved. The
  /// editor keeps this up to date as its fields change.
  bool editorDirty = false;

  Future<bool> Function()? _flushEditor;
  void Function()? _discardEditor;

  /// True while an editor page is open.
  bool get editorOpen => _flushEditor != null;

  /// Called by the editor when it opens: [flush] saves its pending
  /// changes (true on success), [discard] marks them as thrown away so
  /// the editor's own teardown does not save them after all.
  void registerEditor({
    required Future<bool> Function() flush,
    required void Function() discard,
  }) {
    _flushEditor = flush;
    _discardEditor = discard;
  }

  /// Called by the editor when it closes.
  void unregisterEditor() {
    _flushEditor = null;
    _discardEditor = null;
    editorDirty = false;
  }

  /// Runs the open editor's flush, if any. True when nothing is left
  /// unsaved (including when no editor is open).
  Future<bool> flushEditor() async {
    final flush = _flushEditor;
    if (flush == null) return true;
    return flush();
  }

  /// Tells the open editor to drop its unsaved changes. Used when the
  /// user chooses "Quit without saving": without this, the editor being
  /// torn down during exit would save the changes anyway.
  void discardEditor() => _discardEditor?.call();

  // -- Tray "new note" routing ------------------------------------------

  void Function()? _trayNewNote;

  /// Called by the list screen so the tray menu's "New note" can reach
  /// it from anywhere.
  void registerTrayNewNote(void Function() callback) {
    _trayNewNote = callback;
  }

  /// Called by the list screen when it goes away.
  void unregisterTrayNewNote() {
    _trayNewNote = null;
  }

  /// Handles the tray's "New note": asks the list screen to open a fresh
  /// editor. Ignored when an editor is already open — one editor at a
  /// time, and the open one may hold unsaved work.
  void trayNewNote() {
    if (editorOpen) return;
    _trayNewNote?.call();
  }
}

/// Asks what to do about unsaved changes before leaving — closing a
/// note, or quitting the program. Dark themed like the rest of the app.
///
/// Returns 'save', 'discard', or null when the user chooses to stay
/// (the keep-editing button, or dismissing the dialog).
Future<String?> showUnsavedWorkDialog(
  BuildContext context, {
  required String title,
  required String saveLabel,
  required String saveTooltip,
  required String discardLabel,
  required String discardTooltip,
  required String keepLabel,
  required String keepTooltip,
}) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: kSurface,
      title: Text(title),
      content: const Text(
        'This note has changes that have not been saved yet.',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop('keep'),
          child: Tooltip(
            message: keepTooltip,
            child: Text(keepLabel, style: const TextStyle(color: Colors.white)),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop('discard'),
          child: Tooltip(
            message: discardTooltip,
            child: Text(
              discardLabel,
              style: const TextStyle(color: kAccentText),
            ),
          ),
        ),
        ElevatedButton(
          style: primaryButtonStyle(),
          onPressed: () => Navigator.of(dialogContext).pop('save'),
          child: Tooltip(message: saveTooltip, child: Text(saveLabel)),
        ),
      ],
    ),
  );
}

/// The application widget. Tests hand it a ready-made [AppState].
class TermiNoteApp extends StatefulWidget {
  const TermiNoteApp({super.key, required this.state});

  /// Shared state for the whole app.
  final AppState state;

  @override
  State<TermiNoteApp> createState() => _TermiNoteAppState();
}

class _TermiNoteAppState extends State<TermiNoteApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  AppLifecycleListener? _lifecycle;
  bool _exitDialogShowing = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    // Tell the runner the saved tray setting, and listen for tray menu
    // commands. Both are no-ops without the native side (tests).
    unawaited(WindowChannel.setMinimizeToTray(state.minimizeToTray));
    WindowChannel.setTrayCommandHandler((command) async {
      // 'open': the runner has already restored the window.
      if (command == 'newNote') state.trayNewNote();
    });
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    WindowChannel.setTrayCommandHandler(null);
    super.dispose();
  }

  /// The program is being closed (window close button, tray Quit, …).
  /// Settings are flushed on every path. When the open editor holds
  /// unsaved changes, the user is asked first; anything going wrong
  /// still lets the program close — a failure must never trap the user
  /// inside the app.
  Future<ui.AppExitResponse> _onExitRequested() async {
    try {
      await state.saveSettings();
      if (!state.editorDirty) {
        // Nothing unsaved in the editor; still wait for any note write
        // already on its way to disk so quitting cannot cut it short.
        await state.store.saveDirty();
        return ui.AppExitResponse.exit;
      }
      if (_exitDialogShowing) return ui.AppExitResponse.cancel;
      final context = _navigatorKey.currentContext;
      if (context == null) return ui.AppExitResponse.exit;
      _exitDialogShowing = true;
      final choice = await showUnsavedWorkDialog(
        context,
        title: 'Save before quitting?',
        saveLabel: 'Save and quit',
        saveTooltip: 'Save the changes and quit',
        discardLabel: 'Quit without saving',
        discardTooltip: 'Quit now; the unsaved changes are lost',
        keepLabel: 'Keep working',
        keepTooltip: 'Do not quit yet',
      );
      _exitDialogShowing = false;
      switch (choice) {
        case 'save':
          await state.flushEditor();
          return ui.AppExitResponse.exit;
        case 'discard':
          // Without this the editor's teardown would save the changes
          // on the way out anyway.
          state.discardEditor();
          await state.store.saveDirty();
          return ui.AppExitResponse.exit;
        default:
          return ui.AppExitResponse.cancel;
      }
    } on Exception {
      return ui.AppExitResponse.exit;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TermiNote',
      debugShowCheckedModeBanner: false,
      theme: buildTermiNoteTheme(),
      navigatorKey: _navigatorKey,
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
    // The tray menu's "New note" lands here.
    state.registerTrayNewNote(() => _openEditor(null));
  }

  @override
  void dispose() {
    state.unregisterTrayNewNote();
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
    unawaited(state.persist());
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
            unawaited(state.persist());
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
    await state.persist();
    _showUndoSnack('All notes deleted.', () {
      for (final id in ids) {
        store.restore(id);
      }
    });
  }

  void _setSort(SortMode mode) {
    state.sortMode = mode;
    unawaited(state.saveSettings());
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
    unawaited(state.saveSettings());
    unawaited(state.persist());
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final stats = store.stats();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ScanlineBackground(
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
                _openEditor(null),
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _openSearch,
          },
          child: Focus(
            focusNode: _shortcutFocus,
            autofocus: true,
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
          child: Container(
            height: 48,
            decoration: const BoxDecoration(
              borderRadius: BorderRadius.all(Radius.circular(10)),
              boxShadow: primaryGlowShadow,
            ),
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
            borderRadius: BorderRadius.circular(16),
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
        decoration: cardDecoration(
          // The edge brightens to the full accent red on hover, as part
          // of the same hover state as the lift and shadow.
          borderColor: _hovered ? kAccent : kCardBorder,
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
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onOpen,
            child: Stack(
              children: <Widget>[
                // The bright red tick down the left edge: 4px wide,
                // vertically centred on the middle 60% of the card.
                Positioned(
                  left: 8,
                  top: 0,
                  bottom: 0,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      heightFactor: 0.6,
                      child: Container(
                        width: 4,
                        decoration: BoxDecoration(
                          color: kAccent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 10, 8, 14),
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
              ],
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
