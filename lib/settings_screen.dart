/// Settings page: sort order, default text size, the trash, export and
/// import (by typed file path — no file-picker packages), and About.
///
/// Trash entries are shown by title only, like everywhere else outside
/// the editor.
library;

import 'dart:io' as io;

import 'package:flutter/material.dart';

import 'main.dart';
import 'note_store.dart';
import 'theme.dart';

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

  AppState get state => widget.state;
  NoteStore get store => widget.state.store;

  @override
  void dispose() {
    _exportController.dispose();
    _importController.dispose();
    super.dispose();
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  void _export() {
    final path = _exportController.text.trim();
    if (path.isEmpty) {
      _say('Type a file path to export to first.');
      return;
    }
    try {
      io.File(path).writeAsStringSync(store.exportJson());
      _say('Exported ${store.notes.length} note(s) to $path');
    } on io.FileSystemException catch (e) {
      _say('Could not write that file: ${e.message}');
    }
  }

  void _import() {
    final path = _importController.text.trim();
    if (path.isEmpty) {
      _say('Type a file path to import from first.');
      return;
    }
    final file = io.File(path);
    if (!file.existsSync()) {
      _say('No such file: $path');
      return;
    }
    try {
      final count = store.importJson(file.readAsStringSync());
      state.persist();
      setState(() {});
      _say('Imported $count note(s).');
    } on FormatException catch (e) {
      _say('Could not import that file: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = store.stats();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kColumnWidth),
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
                              state.saveSettings();
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
                                state.saveSettings();
                                setState(() {});
                              },
                            ),
                            Text(
                              '${state.textSize.round()} pt — new notes open '
                              'at this size; A− / A+ in the editor change '
                              'it too.',
                              style: const TextStyle(fontSize: 13.5),
                            ),
                            IconButton(
                              tooltip: 'Bigger text',
                              icon: const Icon(Icons.text_increase),
                              onPressed: () {
                                state.textSize = (state.textSize + 1).clamp(
                                  12,
                                  28,
                                );
                                state.saveSettings();
                                setState(() {});
                              },
                            ),
                          ],
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
                                    state.persist();
                                    setState(() {});
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Delete this note for good',
                                  icon: const Icon(Icons.delete_forever),
                                  onPressed: () {
                                    store.deleteForever(note.id);
                                    state.persist();
                                    setState(() {});
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
                                store.emptyTrash();
                                state.persist();
                                setState(() {});
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
                        _sectionTitle('About'),
                        const Text(
                          'TermiNote 0.2.0\n'
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
                          'Data file: ${state.dataPath}',
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
