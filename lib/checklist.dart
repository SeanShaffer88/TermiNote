/// Plain-text checklist helpers. Checklists stay inside the existing
/// Markdown note body, so older notes and exports keep working.
class ChecklistTask {
  const ChecklistTask({required this.text, required this.checked});

  final String text;
  final bool checked;

  ChecklistTask copyWith({String? text, bool? checked}) {
    return ChecklistTask(
      text: text ?? this.text,
      checked: checked ?? this.checked,
    );
  }
}

final RegExp _checklistLine = RegExp(r'^\s*[-*]\s+\[([ xX])\]\s*(.*)$');

/// Parses a note when every non-blank line is a checklist row.
///
/// Returns null for ordinary notes. An empty checklist placeholder such as
/// `- [ ] ` is accepted, which lets an empty to-do list keep its mode.
List<ChecklistTask>? parseChecklistTasks(String body) {
  if (body.trim().isEmpty) return null;
  final tasks = <ChecklistTask>[];
  for (final line in body.replaceAll('\r\n', '\n').split('\n')) {
    if (line.trim().isEmpty) continue;
    final match = _checklistLine.firstMatch(line);
    if (match == null) return null;
    tasks.add(
      ChecklistTask(
        checked: match.group(1)!.toLowerCase() == 'x',
        text: match.group(2)!.trim(),
      ),
    );
  }
  return tasks;
}

/// Writes checklist rows in the Markdown format TermiNote already supports.
/// An empty list keeps one blank row so the editor reopens in checklist mode.
String serializeChecklistTasks(Iterable<ChecklistTask> tasks) {
  final lines = tasks
      .map(
        (task) => (
          text: task.text.trim().replaceAll(RegExp(r'\s+'), ' '),
          checked: task.checked,
        ),
      )
      .where((task) => task.text.isNotEmpty)
      .map((task) => '- [${task.checked ? 'x' : ' '}] ${task.text}')
      .toList();
  return lines.isEmpty ? '- [ ] ' : lines.join('\n');
}

/// Counts non-empty checklist rows in any note body.
({int total, int completed}) checklistCounts(String body) {
  var total = 0;
  var completed = 0;
  for (final line in body.replaceAll('\r\n', '\n').split('\n')) {
    final match = _checklistLine.firstMatch(line);
    if (match == null || match.group(2)!.trim().isEmpty) continue;
    total++;
    if (match.group(1)!.toLowerCase() == 'x') completed++;
  }
  return (total: total, completed: completed);
}
