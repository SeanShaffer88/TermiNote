/// Small editor operations borrowed from full Markdown editors, kept
/// as pure functions wherever possible so they are testable without a
/// widget: duplicate line, move lines, `;date`-style snippets, and the
/// auto-pairing of brackets and quotes while typing.
library;

import 'package:flutter/services.dart';

import 'cli.dart' show formatStamp;

/// The result of an editing operation: the new text plus the
/// selection (start/end offsets) to show afterwards.
typedef EditorEdit = ({String text, int start, int end});

/// Expands a line range out to whole lines (shared shape with the
/// Markdown operations).
(int, int) _wholeLines(String text, int start, int end) {
  var s = start;
  while (s > 0 && text[s - 1] != '\n') {
    s--;
  }
  var e = end;
  if (e > s && text[e - 1] != '\n') {
    while (e < text.length && text[e] != '\n') {
      e++;
    }
  }
  return (s, e);
}

/// Duplicates the selected lines — or the current line when nothing
/// is selected — directly below the original. The selection ends up
/// covering the copy.
EditorEdit duplicateLines(String text, int selStart, int selEnd) {
  var start = selStart.clamp(0, text.length);
  var end = selEnd.clamp(0, text.length);
  if (end < start) {
    final tmp = start;
    start = end;
    end = tmp;
  }
  final (s, e) = _wholeLines(text, start, end);
  final segment = text.substring(s, e);
  final newText = text.replaceRange(e, e, '\n$segment');
  final copyStart = e + 1;
  return (text: newText, start: copyStart, end: copyStart + segment.length);
}

/// Moves the selected lines one line up or down, swapping with the
/// neighbouring line. At the top (moving up) or bottom (moving down)
/// nothing changes. The selection follows the moved lines.
EditorEdit moveLines(
  String text,
  int selStart,
  int selEnd, {
  required bool up,
}) {
  var start = selStart.clamp(0, text.length);
  var end = selEnd.clamp(0, text.length);
  if (end < start) {
    final tmp = start;
    start = end;
    end = tmp;
  }
  final (s, e) = _wholeLines(text, start, end);
  final segment = text.substring(s, e);
  if (up) {
    if (s == 0) return (text: text, start: start, end: end);
    // The line above: from its start to just before the segment.
    var aboveStart = s - 1;
    while (aboveStart > 0 && text[aboveStart - 1] != '\n') {
      aboveStart--;
    }
    final above = text.substring(aboveStart, s - 1);
    final newText = text.replaceRange(aboveStart, e, '$segment\n$above');
    return (text: newText, start: aboveStart, end: aboveStart + segment.length);
  }
  if (e >= text.length) return (text: text, start: start, end: end);
  // The line below: from just after the segment to its end.
  var belowEnd = e + 1;
  while (belowEnd < text.length && text[belowEnd] != '\n') {
    belowEnd++;
  }
  final below = text.substring(e + 1, belowEnd);
  final newText = text.replaceRange(s, belowEnd, '$below\n$segment');
  final newStart = s + below.length + 1;
  return (text: newText, start: newStart, end: newStart + segment.length);
}

/// Snippet words and what they expand to. Typed in the body, a
/// snippet expands the moment its last letter is typed.
const Map<String, String> _snippetWords = <String, String>{
  ';date': 'date',
  ';time': 'time',
  ';now': 'now',
};

/// When the text right before [cursor] is exactly a snippet word,
/// returns the text with the word replaced by its expansion for
/// [nowSeconds] (unix seconds, local time); otherwise null.
EditorEdit? expandSnippet(String text, int cursor, int nowSeconds) {
  if (cursor < 0 || cursor > text.length) return null;
  final before = text.substring(0, cursor);
  for (final entry in _snippetWords.entries) {
    final word = entry.key;
    if (!before.endsWith(word)) continue;
    // The word must start the text or follow a space/newline, so a
    // longer word ending the same way never expands by accident.
    final at = cursor - word.length;
    if (at > 0 && before[at - 1] != ' ' && before[at - 1] != '\n') {
      continue;
    }
    final stamp = formatStamp(nowSeconds);
    final expansion = switch (entry.value) {
      'date' => stamp.substring(0, 10),
      // formatStamp is "YYYY-MM-DD (Day) HH:MM:SS AM" — the time is
      // the part after the ") ".
      'time' => stamp.substring(stamp.indexOf(') ') + 2),
      _ => stamp,
    };
    return (
      text: text.replaceRange(at, cursor, expansion),
      start: at + expansion.length,
      end: at + expansion.length,
    );
  }
  return null;
}

/// Opening characters and their closing partners for auto-pairing.
const Map<String, String> _pairs = <String, String>{
  '(': ')',
  '[': ']',
  '{': '}',
  '"': '"',
  "'": "'",
  '`': '`',
};

const Set<String> _closers = <String>{')', ']', '}', '"', "'", '`'};

/// The pure heart of [AutoPairFormatter]: given the field value
/// before and after one edit, returns the value that should actually
/// be used. Cases:
///
/// - Typed an opener with nothing selected → the closer is added
///   after the cursor, which stays between the pair. (A single quote
///   after a letter is an apostrophe, not a pair, and is left alone.)
/// - Typed a closer and the same closer was already the next
///   character → the cursor just steps over it, no duplicate.
/// - Typed an opener over a selection → the selected text is wrapped
///   in the pair and stays selected (inside the marks).
/// - Anything else → [newValue] unchanged.
TextEditingValue autoPairTransform(
  TextEditingValue oldValue,
  TextEditingValue newValue,
) {
  final oldText = oldValue.text;
  final newText = newValue.text;
  final oldSel = oldValue.selection;
  final newSel = newValue.selection;

  // Wrap a selection: the old selection was replaced by exactly one
  // opener character.
  if (oldSel.isValid &&
      !oldSel.isCollapsed &&
      newSel.isValid &&
      newSel.isCollapsed &&
      newText.length == oldText.length - (oldSel.end - oldSel.start) + 1) {
    final typedAt = newSel.start - 1;
    if (typedAt >= 0 && typedAt < newText.length) {
      final typed = newText[typedAt];
      final closer = _pairs[typed];
      if (closer != null &&
          newText ==
              '${oldText.substring(0, oldSel.start)}$typed'
                  '${oldText.substring(oldSel.end)}') {
        final selected = oldText.substring(oldSel.start, oldSel.end);
        final wrapped = '$typed$selected$closer';
        return TextEditingValue(
          text: newText.replaceRange(typedAt, typedAt + 1, wrapped),
          selection: TextSelection(
            baseOffset: typedAt + 1,
            extentOffset: typedAt + 1 + selected.length,
          ),
        );
      }
    }
    return newValue;
  }

  // Single-character insertion with a collapsed cursor on both sides.
  if (!oldSel.isValid ||
      !oldSel.isCollapsed ||
      !newSel.isValid ||
      !newSel.isCollapsed ||
      newText.length != oldText.length + 1 ||
      newSel.start != oldSel.start + 1) {
    return newValue;
  }
  final cursor = newSel.start;
  final typed = newText[cursor - 1];
  final nextChar = cursor < newText.length ? newText[cursor] : null;

  // Step over an existing closer.
  if (_closers.contains(typed) && nextChar == typed) {
    return TextEditingValue(
      text: newText.replaceRange(cursor, cursor + 1, ''),
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
  final closer = _pairs[typed];
  if (closer == null) return newValue;
  // An apostrophe inside a word is not a pair.
  if (typed == "'" && cursor >= 2 && _isLetter(newText[cursor - 2])) {
    return newValue;
  }
  return TextEditingValue(
    text: newText.replaceRange(cursor, cursor, closer),
    selection: TextSelection.collapsed(offset: cursor),
  );
}

bool _isLetter(String ch) {
  final code = ch.codeUnitAt(0);
  return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
}

/// A [TextInputFormatter] that auto-pairs brackets and quotes in the
/// body field, using [autoPairTransform] for every edit.
class AutoPairFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => autoPairTransform(oldValue, newValue);
}
