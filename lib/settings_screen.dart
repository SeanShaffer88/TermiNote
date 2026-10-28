/// Settings page: sort order, default text size, the trash, export and
/// import (by typed file path — no file-picker packages), and About.
///
/// Trash entries are shown by title only, like everywhere else outside
/// the editor.
library;

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';

import 'main.dart';
import 'note_store.dart';
import 'theme.dart';
import 'version.dart';
import 'window_channel.dart';

/// The settings page, pushed over the list.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.state});

  /// Shared app state.
  final AppState state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _exportController = TextEditingController();
  final TextEditingController _importController = TextEditingController();
  final TextEditingController _backupController = TextEditingController();
  final TextEditingController _restoreController = TextEditingController();

  AppState get state => widget.state;
  NoteStore get store => widget.state.store;

  @override
  void dispose() {
    _exportController.dispose();
    _importController.dispose();
    _backupController.dispose();
    _restoreController.dispose();
    super.dispose();
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> _export() async {
    final path = _exportController.text.trim();
    if (path.isEmpty) {
      _say('Type a file path to export to first.');
      return;
    }
    try {
      await io.File(path).writeAsString(store.exportJson());
      _say('Exported ${store.notes.length} note(s) to $path');
    } on io.FileSystemException catch (e) {
      _say('Could not write that file: ${e.message}');
    }
  }

  Future<void> _import() async {
    final path = _importController.text.trim();
    if (path.isEmpty) {
      _say('Type a file path to import from first.');
      return;
    }
    final String text;
    try {
      text = await io.File(path).readAsString();
    } on io.FileSystemException {
      _say('No such file: $path');
      return;
    }
    try {
      final result = store.importJson(text);
      await state.persist();
      if (!mounted) return;
      setState(() {});
      if (result.skipped == 0) {
        _say('Imported ${result.imported} note(s).');
      } else {
        _say(
          'Imported ${result.imported} note(s); ${result.skipped} were '
          'already there and were skipped.',
        );
      }
    } on FormatException catch (e) {
      _say('Could not import that file: ${e.message}');
    }
  }

  /// Asks before something that cannot be undone — deleting notes for
  /// good, or restoring a backup — in the app's dialog style. Returns
  /// true only when the user chose the confirming button.
  Future<bool> _askToConfirm({
    required String title,
    required String body,
    required String confirmLabel,
    required String confirmTooltip,
    required String cancelTooltip,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kSurface,
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Tooltip(
              message: cancelTooltip,
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
          ElevatedButton(
            style: primaryButtonStyle(),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Tooltip(message: confirmTooltip, child: Text(confirmLabel)),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _deleteForever(Note note) async {
    final confirmed = await _askToConfirm(
      title: 'Delete this note for good?',
      body:
          '"${note.title}" will be deleted permanently. '
          'This cannot be undone.',
      confirmLabel: 'Delete for good',
      confirmTooltip: 'Delete this note permanently',
      cancelTooltip: 'Keep this note in the trash',
    );
    if (!confirmed || !mounted) return;
    store.deleteForever(note.id);
    unawaited(state.persist());
    setState(() {});
  }

  Future<void> _emptyTrash() async {
    final confirmed = await _askToConfirm(
      title: 'Empty the trash?',
      body:
          'All ${store.trash.length} note(s) in the trash will be '
          'deleted permanently. This cannot be undone.',
      confirmLabel: 'Delete for good',
      confirmTooltip: 'Delete every trashed note permanently',
      cancelTooltip: 'Keep the notes in the trash',
    );
    if (!confirmed || !mounted) return;
    store.emptyTrash();
    unawaited(state.persist());
    setState(() {});
  }

  Future<void> _backup() async {
    final path = _backupController.text.trim();
    if (path.isEmpty) {
      _say('Type a folder path to back up to first.');
      return;
    }
    try {
      // The backup copies the files on disk, so anything still waiting
      // to be written has to land first.
      await state.persist();
      final count = await store.backupNotesTo(path);
      _say('Backed up $count note file(s) to $path');
    } on ArgumentError {
      _say(
        'That folder is the notes folder or inside it — '
        'choose somewhere else.',
      );
    } on io.FileSystemException catch (e) {
      _say('Could not back up there: ${e.message}');
    }
  }

  Future<void> _restore() async {
    final path = _restoreController.text.trim();
    if (path.isEmpty) {
      _say('Type a folder path to restore from first.');
      return;
    }
    final confirmed = await _askToConfirm(
      title: 'Restore backup?',
      body:
          'This adds the backed-up notes alongside your current '
          'ones — nothing is overwritten.',
      confirmLabel: 'Restore',
      confirmTooltip: 'Add the backed-up notes to this notebook',
      cancelTooltip: 'Do not restore anything',
    );
    if (!confirmed || !mounted) return;
    try {
      final result = await store.restoreNotesFrom(path);
      await state.persist();
      if (!mounted) return;
      setState(() {});
      if (result.skipped == 0) {
        _say('Restored ${result.restored} note(s).');
      } else {
        _say(
          'Restored ${result.restored} note(s); ${result.skipped} '
          'file(s) could not be read and were skipped.',
        );
      }
    } on io.FileSystemException catch (e) {
      _say('Could not restore from there: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = store.stats();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ScanlineBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back, size: 26),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(
                    children: <Widget>[
                      _sectionTitle('Sort order'),
                      for (final (mode, label) in <(SortMode, String)>[
                        (SortMode.modifiedDesc, 'Newest changed first'),
                        (SortMode.titleAsc, 'Title A to Z'),
                        (SortMode.createdDesc, 'Newest created first'),
                        (SortMode.manual, 'My drag order'),
                      ])
                        InkWell(
                          onTap: () {
                            state.sortMode = mode;
                            unawaited(state.saveSettings());
                            setState(() {});
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 9,
                              horizontal: 4,
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  state.sortMode == mode
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  color: state.sortMode == mode
                                      ? kAccent
                                      : kDim,
                                  size: 21,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  label,
                                  style: const TextStyle(fontSize: 15),
                                ),
                              ],
                            ),
                          ),
                        ),
                      _sectionTitle('Text size'),
                      Row(
                        children: <Widget>[
                          IconButton(
                            tooltip: 'Smaller text',
                            icon: const Icon(Icons.text_decrease),
                            onPressed: () {
                              state.textSize = (state.textSize - 1).clamp(
                                12,
                                28,
                              );
                              unawaited(state.saveSettings());
                              setState(() {});
                            },
                          ),
                          Expanded(
                            child: Text(
                              '${state.textSize.round()} pt — new notes open '
                              'at this size; A− / A+ in the editor change '
                              'it too.',
                              style: const TextStyle(fontSize: 13.5),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Bigger text',
                            icon: const Icon(Icons.text_increase),
                            onPressed: () {
                              state.textSize = (state.textSize + 1).clamp(
                                12,
                                28,
                              );
                              unawaited(state.saveSettings());
                              setState(() {});
                            },
                          ),
                        ],
                      ),
                      _sectionTitle('System tray'),
                      Row(
                        children: <Widget>[
                          const Expanded(
                            child: Text(
                              'Minimize to the system tray',
                              style: TextStyle(fontSize: 15),
                            ),
                          ),
                          Tooltip(
                            message: 'Minimize to the system tray',
                            child: Switch(
                              value: state.minimizeToTray,
                              activeTrackColor: kAccent,
                              onChanged: (value) {
                                state.minimizeToTray = value;
                                unawaited(state.saveSettings());
                                unawaited(
                                  WindowChannel.setMinimizeToTray(value),
                                );
                                setState(() {});
                              },
                            ),
                          ),
                        ],
                      ),
                      const Text(
                        'The minimize button tucks TermiNote into the tray '
                        'by the clock. The tray icon\'s menu can open it, '
                        'start a new note, or quit.',
                        style: TextStyle(color: kDim, fontSize: 13),
                      ),
                      _sectionTitle('Trash'),
                      if (store.trash.isEmpty)
                        const Text(
                          '> trash is empty',
                          style: TextStyle(color: kDim),
                        ),
                      for (final note in store.trash)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            note.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              IconButton(
                                tooltip: 'Restore this note',
                                icon: const Icon(Icons.restore_from_trash),
                                onPressed: () {
                                  store.restore(note.id);
                                  unawaited(state.persist());
                                  setState(() {});
                                },
                              ),
                              IconButton(
                                tooltip: 'Delete this note for good',
                                icon: const Icon(Icons.delete_forever),
                                onPressed: () {
                                  unawaited(_deleteForever(note));
                                },
                              ),
                            ],
                          ),
                        ),
                      if (store.trash.isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () {
                              unawaited(_emptyTrash());
                            },
                            child: const Text(
                              'Empty trash',
                              style: TextStyle(color: kAccentText),
                            ),
                          ),
                        ),
                      _sectionTitle('Export notes'),
                      _pathRow(
                        controller: _exportController,
                        hint: 'File path, e.g. C:\\Users\\you\\notes.json',
                        buttonLabel: 'Export',
                        onPressed: _export,
                      ),
                      _sectionTitle('Import notes'),
                      _pathRow(
                        controller: _importController,
                        hint: 'File path of a TermiNote export',
                        buttonLabel: 'Import',
                        onPressed: _import,
                      ),
                      _sectionTitle('Back up notes'),
                      _pathRow(
                        controller: _backupController,
                        hint: 'Folder path, e.g. D:\\Backups\\TermiNote',
                        buttonLabel: 'Back up',
                        onPressed: _backup,
                      ),
                      const Text(
                        'Copies every note file (the trash too) into that '
                        'folder, in the same notes layout — the copy can '
                        'be restored below, or read as plain Markdown.',
                        style: TextStyle(color: kDim, fontSize: 13),
                      ),
                      _sectionTitle('Restore backup'),
                      _pathRow(
                        controller: _restoreController,
                        hint: 'Folder path of a backup made earlier',
                        buttonLabel: 'Restore',
                        onPressed: _restore,
                      ),
                      const Text(
                        'Adds the backed-up notes alongside your current '
                        'ones. Nothing is overwritten.',
                        style: TextStyle(color: kDim, fontSize: 13),
                      ),
                      _sectionTitle('About'),
                      const Text(
                        'TermiNote $kAppVersion\n'
                        'A dark terminal-themed notepad.\n'
                        'Free software, MIT licence.\n'
                        'Works fully offline. No account, no ads, '
                        'no data sold.',
                        style: TextStyle(fontSize: 14, height: 1.5),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Notes: ${stats.notes} · In trash: ${stats.trash}'
                        ' · Tags: ${stats.tags} · Pinned: ${stats.pinned}',
                        style: const TextStyle(color: kDim, fontSize: 13),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Notes folder: ${state.notesDir}',
                        style: const TextStyle(color: kDim, fontSize: 13),
                      ),
                      const SizedBox(height: 24),
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

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _pathRow({
    required TextEditingController controller,
    required String hint,
    required String buttonLabel,
    required VoidCallback onPressed,
  }) {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            cursorColor: kAccent,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: kDim, fontSize: 13),
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
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 46,
          child: ElevatedButton(
            style: darkButtonStyle(),
            onPressed: onPressed,
            child: Text(buttonLabel),
          ),
        ),
      ],
    );
  }
}
