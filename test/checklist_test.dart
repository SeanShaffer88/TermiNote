import 'package:flutter_test/flutter_test.dart';

import 'package:terminote/checklist.dart';

void main() {
  group('checklist helpers', () {
    test('parses and serializes checked and unchecked rows', () {
      final tasks = parseChecklistTasks('- [ ] Milk\n- [x] Bread');

      expect(tasks, isNotNull);
      expect(tasks!.map((task) => task.text), <String>['Milk', 'Bread']);
      expect(tasks.map((task) => task.checked), <bool>[false, true]);
      expect(serializeChecklistTasks(tasks), '- [ ] Milk\n- [x] Bread');
    });

    test('rejects ordinary notes and preserves an empty checklist marker', () {
      expect(parseChecklistTasks('A normal note'), isNull);
      expect(parseChecklistTasks('- [ ] '), hasLength(1));
      expect(serializeChecklistTasks(const <ChecklistTask>[]), '- [ ] ');
    });

    test('counts completed non-empty rows', () {
      expect(checklistCounts('- [x] One\n- [ ] Two\n- [ ] ').total, 2);
      expect(checklistCounts('- [x] One\n- [ ] Two').completed, 1);
    });
  });
}
