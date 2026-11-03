import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/editor_ops.dart';

void main() {
  group('duplicateLines', () {
    test('duplicates the current line below and selects the copy', () {
      final result = duplicateLines('one\ntwo\nthree', 5, 5);
      expect(result.text, 'one\ntwo\ntwo\nthree');
      expect(result.text.substring(result.start, result.end), 'two');
    });

    test('duplicates the last line without a trailing newline', () {
      final result = duplicateLines('one\ntwo', 6, 6);
      expect(result.text, 'one\ntwo\ntwo');
    });

    test('duplicates every line a selection touches', () {
      final result = duplicateLines('one\ntwo\nthree', 1, 6);
      expect(result.text, 'one\ntwo\none\ntwo\nthree');
    });
  });

  group('moveLines', () {
    test('moves a line up and down, selection following', () {
      final up = moveLines('one\ntwo\nthree', 5, 5, up: true);
      expect(up.text, 'two\none\nthree');
      expect(up.text.substring(up.start, up.end), 'two');
      final down = moveLines(up.text, up.start, up.end, up: false);
      expect(down.text, 'one\ntwo\nthree');
    });

    test('moving past either end changes nothing', () {
      expect(moveLines('one\ntwo', 1, 1, up: true).text, 'one\ntwo');
      expect(moveLines('one\ntwo', 5, 5, up: false).text, 'one\ntwo');
    });
  });

  group('expandSnippet', () {
    // 2022-11-30 13:23:51 local — a Wednesday.
    final seconds =
        DateTime(2022, 11, 30, 13, 23, 51).millisecondsSinceEpoch ~/ 1000;

    test(';date expands to the date', () {
      final result = expandSnippet('met on ;date', 12, seconds);
      expect(result, isNotNull);
      expect(result!.text, 'met on 2022-11-30');
      expect(result.start, 17);
    });

    test(';time expands to the time and ;now to the full stamp', () {
      final time = expandSnippet(';time', 5, seconds);
      expect(time!.text, '01:23:51 PM');
      final now = expandSnippet(';now', 4, seconds);
      expect(now!.text, '2022-11-30 (Wed) 01:23:51 PM');
    });

    test('a snippet inside a longer word does not expand', () {
      expect(expandSnippet('x;date', 6, seconds), isNull);
      expect(expandSnippet('nothing here', 12, seconds), isNull);
    });
  });

  group('autoPairTransform', () {
    TextEditingValue value(String text, int cursor) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );

    test('typing an opener adds the closer, cursor between', () {
      final result = autoPairTransform(value('ab', 2), value('ab(', 3));
      expect(result.text, 'ab()');
      expect(result.selection.start, 3);
    });

    test('typing a closer over the auto-added one steps over it', () {
      final result = autoPairTransform(value('ab()', 3), value('ab())', 4));
      expect(result.text, 'ab()');
      expect(result.selection.start, 4);
    });

    test('an apostrophe inside a word is left alone', () {
      final result = autoPairTransform(value('don', 3), value("don't", 4));
      expect(result.text, "don't");
    });

    test('typing an opener over a selection wraps it', () {
      final old = TextEditingValue(
        text: 'say word now',
        selection: const TextSelection(baseOffset: 4, extentOffset: 8),
      );
      const after = TextEditingValue(
        text: 'say ( now',
        selection: TextSelection.collapsed(offset: 5),
      );
      final result = autoPairTransform(old, after);
      expect(result.text, 'say (word) now');
      expect(
        result.text.substring(result.selection.start, result.selection.end),
        'word',
      );
    });

    test('ordinary typing passes through unchanged', () {
      final after = value('abx', 3);
      expect(autoPairTransform(value('ab', 2), after).text, 'abx');
    });
  });
}
