/// Recycle-bin view for restoring or permanently removing deleted notes.
library;

import 'package:material_ui/material_ui.dart';

import 'note_store.dart';
import 'theme.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.store, required this.onChanged});

  final NoteStore store;
  final Future<void> Function() onChanged;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  NoteStore get store => widget.store;

  String _dateLabel(int seconds) {
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  String _preview(String body) {
    final plain = body
        .replaceAll(RegExp(r'^\s*[-*]\s+\[[ xX]\]\s*', multiLine: true), '')
        .replaceAll(RegExp(r'[#*_~`>\[\]()]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return plain.isEmpty ? 'No additional text' : plain;
  }

  Future<bool> _saveChange() async {
    try {
      await widget.onChanged();
      return true;
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save. Keep TermiNote open and retry.'),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _restore(Note note) async {
    if (!store.restore(note.id)) return;
    final saved = await _saveChange();
    if (!mounted) return;
    setState(() {});
    if (!saved) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Note restored.')));
  }

  Future<void> _deleteForever(Note note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text('"${note.title}" cannot be restored after deletion.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: primaryButtonStyle(),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    store.deleteForever(note.id);
    final saved = await _saveChange();
    if (mounted) setState(() {});
    if (!saved) return;
  }

  Future<void> _emptyTrash() async {
    if (store.trash.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Empty Recycle Bin?'),
        content: Text(
          'This permanently deletes ${store.trash.length} note(s). '
          'This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: primaryButtonStyle(),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Empty bin'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    store.emptyTrash();
    final saved = await _saveChange();
    if (mounted) setState(() {});
    if (!saved) return;
  }

  @override
  Widget build(BuildContext context) {
    final notes = store.trash;
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
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Recycle Bin',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (notes.isNotEmpty)
                      TextButton.icon(
                        onPressed: _emptyTrash,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('Empty bin'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${notes.length} ${notes.length == 1 ? 'note' : 'notes'}',
                  style: const TextStyle(color: kDim),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: notes.isEmpty
                      ? const Center(
                          child: Text(
                            'Recycle Bin is empty',
                            style: TextStyle(color: kDim, fontSize: 17),
                          ),
                        )
                      : ListView.separated(
                          itemCount: notes.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, color: kBorder),
                          itemBuilder: (context, index) {
                            final note = notes[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 4,
                              ),
                              child: Row(
                                children: <Widget>[
                                  CircleAvatar(
                                    radius: 22,
                                    backgroundColor: kSurfaceAlt,
                                    child: Icon(
                                      note.body.contains(RegExp(r'\[[ xX]\]'))
                                          ? Icons.checklist
                                          : Icons.edit_outlined,
                                      color: kAccentText,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          note.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _preview(note.body),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(color: kDim),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: <Widget>[
                                      Text(
                                        _dateLabel(note.modified),
                                        style: const TextStyle(color: kDim),
                                      ),
                                      const Text(
                                        'Kept until you delete it',
                                        style: TextStyle(
                                          color: kDim,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Restore note',
                                    onPressed: () => _restore(note),
                                    icon: const Icon(
                                      Icons.restore_from_trash,
                                      color: kAccentText,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete forever',
                                    onPressed: () => _deleteForever(note),
                                    icon: const Icon(Icons.delete_forever),
                                  ),
                                ],
                              ),
                            );
                          },
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
