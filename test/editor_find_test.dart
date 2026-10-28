// Widget tests for find-in-a-note: Ctrl+F in the editor opens a find
// bar that counts matches in plain words, selects them in the body
// field as it steps, and closes with Esc.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/main.dart';
import 'package:terminote/note_store.dart';

/// Sends Ctrl+F the way a keyboard would: control down, F, control up.
Future<void> _ctrlF(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Finder _bodyField() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == 'Write your note',
);

Finder _findField() => find.byKey(const ValueKey<String>('find-field'));

TextEditingController _bodyController(WidgetTester tester) =>
    tester.widget<TextField>(_bodyField()).controller!;

void main() {
  // A full-size surface, like the suite's other screen tests: at the
  // default 800x600 the editor uses its scrolling layout and the
  // find bar sits half-clipped at the bottom edge, where taps on its
  // buttons cannot land.
  void useFullSizeSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('Ctrl+F finds, counts, and steps through matches', (
    tester,
  ) async {
    useFullSizeSurface(tester);
    final dir = Directory.systemTemp.createTempSync('terminote_find_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = NoteStore.empty();
    store.add(title: 'Find target', body: 'one two one two one', now: 100);
    final state = AppState(store: store, dataDir: dir.path);

    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('Find target'));
    await tester.pumpAndSettle();
    expect(_findField(), findsNothing);

    // Ctrl+F opens the bar under the toolbar.
    await _ctrlF(tester);
    expect(_findField(), findsOneWidget);
    expect(find.text('Find in this note'), findsOneWidget);

    // "one" occurs three times, at offsets 0, 8, and 16. Typing the
    // query counts them and selects the first.
    await tester.enterText(_findField(), 'one');
    await tester.pump();
    expect(find.text('match 1 of 3'), findsOneWidget);
    var selection = _bodyController(tester).selection;
    expect(selection.baseOffset, 0);
    expect(selection.extentOffset, 3);

    // The Next button steps through the matches, wrapping at the
    // end; Previous steps back (wrapping to the last match).
    await tester.tap(
      find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
    );
    await tester.pump();
    expect(find.text('match 2 of 3'), findsOneWidget);
    selection = _bodyController(tester).selection;
    expect(selection.baseOffset, 8);
    expect(selection.extentOffset, 11);
    await tester.tap(
      find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
    );
    await tester.pump();
    expect(find.text('match 3 of 3'), findsOneWidget);
    selection = _bodyController(tester).selection;
    expect(selection.baseOffset, 16);
    expect(selection.extentOffset, 19);
    await tester.tap(
      find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
    );
    await tester.pump();
    expect(find.text('match 1 of 3'), findsOneWidget);
    selection = _bodyController(tester).selection;
    expect(selection.baseOffset, 0);
    await tester.tap(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up));
    await tester.pump();
    expect(find.text('match 3 of 3'), findsOneWidget);
    selection = _bodyController(tester).selection;
    expect(selection.baseOffset, 16);
    expect(selection.extentOffset, 19);

    // Enter steps to the next match too (wrapping to the first).
    // Note: after a synthetic Enter the test harness drops the
    // field's focus, so the button taps above run before this.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('match 1 of 3'), findsOneWidget);
    selection = _bodyController(tester).selection;
    expect(selection.baseOffset, 0);
    expect(selection.extentOffset, 3);

    // A query with no matches says so, in plain words, and the step
    // buttons switch off.
    await tester.enterText(_findField(), 'zebra');
    await tester.pump();
    expect(find.text('no matches'), findsOneWidget);
    final nextButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Next match',
      ),
    );
    expect(nextButton.onPressed, isNull);

    // Esc closes the bar (the editor stays open) and the focus returns
    // to the body field.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_findField(), findsNothing);
    expect(_bodyField(), findsOneWidget);
    expect(tester.widget<TextField>(_bodyField()).focusNode?.hasFocus, isTrue);
  });

  testWidgets('find is case-insensitive', (tester) async {
    final dir = Directory.systemTemp.createTempSync('terminote_find_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final store = NoteStore.empty();
    store.add(title: 'Case note', body: 'Cat cat CAT', now: 100);
    final state = AppState(store: store, dataDir: dir.path);

    await tester.pumpWidget(TermiNoteApp(state: state));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('Case note'));
    await tester.pumpAndSettle();
    await _ctrlF(tester);
    await tester.enterText(_findField(), 'cat');
    await tester.pump();
    expect(find.text('match 1 of 3'), findsOneWidget);
  });
}
