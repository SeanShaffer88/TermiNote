/// Markdown support for TermiNote note bodies: the formatting
/// operations behind the editor's toolbar, a tolerant parser for the
/// common Markdown shapes, and a plain-text rendering of a parsed note
/// (used by the CLI's `render` command; the window's preview paints the
/// same parse tree with the app theme, see markdown_view.dart).
///
/// Pure Dart, no packages — the app is zero-dependency by design, and
/// everything here is testable without a widget in sight.
///
/// Supported: headings (`#` to `######`), bold (`**` / `__`), italic
/// (`*` / `_`), strikethrough (`~~`), inline code (backticks), links
/// (`[text](url)`), bullet lists (`-`, `*`, `•`), numbered lists,
/// checklists (`- [ ]` / `- [x]`), quotes (`>`), fenced code blocks
/// (```), and horizontal rules (`---`, `***`, `___`). Anything else —
/// including markers that never close — is plain text, exactly as
/// typed. Nothing is ever thrown away.
library;

// -- Inline spans -------------------------------------------------------

/// One run of text with one set of marks. Marks combine: a span can be
/// bold and italic at once.
class MdSpan {
  const MdSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.strike = false,
    this.linkUrl,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  final bool strike;

  /// The link target when this span is a link, otherwise null.
  final String? linkUrl;

  MdSpan withMarks({bool? bold, bool? italic}) => MdSpan(
    text,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    code: code,
    strike: strike,
    linkUrl: linkUrl,
  );

  @override
  bool operator ==(Object other) =>
      other is MdSpan &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code &&
      other.strike == strike &&
      other.linkUrl == linkUrl;

  @override
  int get hashCode => Object.hash(text, bold, italic, code, strike, linkUrl);

  @override
  String toString() =>
      'MdSpan("$text"${bold ? ' bold' : ''}${italic ? ' italic' : ''}'
      '${code ? ' code' : ''}${strike ? ' strike' : ''}'
      '${linkUrl != null ? ' -> $linkUrl' : ''})';
}

/// Tries one paired marker (`**`, `*`, `~~`, …) at [i]: when [text]
/// starts with [marker] at [i] and a closing [marker] exists later
/// with at least one character between them, returns the inner text
/// and the index just past the closing marker. Otherwise null.
(String, int)? _paired(String text, int i, String marker) {
  if (!text.startsWith(marker, i)) return null;
  final close = text.indexOf(marker, i + marker.length);
  if (close <= i + marker.length) return null;
  return (text.substring(i + marker.length, close), close + marker.length);
}

/// Parses the inline marks in [text] into spans. Unclosed markers stay
/// literal text. Link labels and bold/italic contents are parsed
/// recursively, so marks nest the way writers expect.
List<MdSpan> parseInline(String text) {
  final spans = <MdSpan>[];
  var plain = StringBuffer();

  void flush() {
    if (plain.isNotEmpty) {
      spans.add(MdSpan(plain.toString()));
      plain = StringBuffer();
    }
  }

  void addInner(String inner, {bool? bold, bool? italic, String? linkUrl}) {
    flush();
    for (final innerSpan in parseInline(inner)) {
      var span = innerSpan;
      if (bold != null || italic != null) {
        span = span.withMarks(bold: bold, italic: italic);
      }
      if (linkUrl != null) {
        span = MdSpan(
          span.text,
          bold: span.bold,
          italic: span.italic,
          code: span.code,
          strike: span.strike,
          linkUrl: linkUrl,
        );
      }
      spans.add(span);
    }
  }

  var i = 0;
  while (i < text.length) {
    // Inline code: contents are literal, no marks inside.
    if (text[i] == '`') {
      final close = text.indexOf('`', i + 1);
      if (close > i) {
        flush();
        spans.add(MdSpan(text.substring(i + 1, close), code: true));
        i = close + 1;
        continue;
      }
    }
    // Link: [label](url)
    if (text[i] == '[') {
      final labelEnd = text.indexOf('](', i + 1);
      if (labelEnd > i + 1) {
        final urlEnd = text.indexOf(')', labelEnd + 2);
        if (urlEnd > labelEnd + 2) {
          addInner(
            text.substring(i + 1, labelEnd),
            linkUrl: text.substring(labelEnd + 2, urlEnd),
          );
          i = urlEnd + 1;
          continue;
        }
      }
    }
    // Bold + italic.
    final triple = _paired(text, i, '***');
    if (triple != null) {
      addInner(triple.$1, bold: true, italic: true);
      i = triple.$2;
      continue;
    }
    // Bold.
    var consumed = false;
    for (final marker in const <String>['**', '__']) {
      final pair = _paired(text, i, marker);
      if (pair != null) {
        addInner(pair.$1, bold: true);
        i = pair.$2;
        consumed = true;
        break;
      }
    }
    if (consumed) continue;
    // Strikethrough.
    final strike = _paired(text, i, '~~');
    if (strike != null) {
      flush();
      for (final innerSpan in parseInline(strike.$1)) {
        spans.add(
          MdSpan(
            innerSpan.text,
            bold: innerSpan.bold,
            italic: innerSpan.italic,
            code: innerSpan.code,
            strike: true,
            linkUrl: innerSpan.linkUrl,
          ),
        );
      }
      i = strike.$2;
      continue;
    }
    // Italic. A single `*` or `_` with no closing twin stays literal;
    // `_` inside a word (snake_case) is not italic either.
    for (final marker in const <String>['*', '_']) {
      if (text.startsWith(marker, i) &&
          (marker == '*' || i == 0 || text[i - 1] == ' ')) {
        final pair = _paired(text, i, marker);
        if (pair != null) {
          addInner(pair.$1, italic: true);
          i = pair.$2;
          consumed = true;
          break;
        }
      }
    }
    if (consumed) continue;
    plain.write(text[i]);
    i++;
  }
  flush();
  return spans;
}

/// The plain text of a line with every inline marker removed — link
/// labels keep their text, code keeps its contents.
String inlinePlainText(String text) =>
    parseInline(text).map((s) => s.text).join();

// -- Blocks -------------------------------------------------------------

enum MdBlockKind {
  heading,
  paragraph,
  bulletList,
  numberedList,
  checklist,
  codeBlock,
  quote,
  rule,
}

/// One checklist row: whether it is ticked, plus its text as spans.
class MdCheckItem {
  const MdCheckItem({required this.checked, required this.spans});
  final bool checked;
  final List<MdSpan> spans;
}

/// One block of a parsed note. Which fields matter depends on [kind]:
/// heading uses [level] + [spans]; paragraph uses [spans]; the list
/// kinds use [items] (checklist uses [checkItems]); codeBlock and a
/// quote's raw lines use [rawText] (quote also exposes [spans] per
/// line via [quoteLines]); rule uses none.
class MdBlock {
  const MdBlock(
    this.kind, {
    this.level = 0,
    this.spans = const <MdSpan>[],
    this.items = const <List<MdSpan>>[],
    this.checkItems = const <MdCheckItem>[],
    this.quoteLines = const <List<MdSpan>>[],
    this.rawText = '',
    this.startNumber = 1,
  });

  final MdBlockKind kind;

  /// Heading level 1–6.
  final int level;
  final List<MdSpan> spans;

  /// Rows of a bullet or numbered list, each row as spans.
  final List<List<MdSpan>> items;

  /// Rows of a checklist.
  final List<MdCheckItem> checkItems;

  /// A quote's lines, each as spans.
  final List<List<MdSpan>> quoteLines;

  /// Literal text of a code block.
  final String rawText;

  /// First number of a numbered list.
  final int startNumber;
}

final RegExp _headingRe = RegExp(r'^(#{1,6})\s+(.*)$');
final RegExp _bulletRe = RegExp(r'^\s*[-*•]\s+(.*)$');
final RegExp _numberedRe = RegExp(r'^\s*(\d+)[.)]\s+(.*)$');
final RegExp _checkRe = RegExp(r'^\s*[-*•]\s+\[([ xX])\]\s+(.*)$');
final RegExp _quoteRe = RegExp(r'^\s*>\s?(.*)$');
final RegExp _ruleRe = RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$');

/// Parses a note body into blocks. Blank lines separate blocks;
/// consecutive list / checklist / quote lines group together; a fenced
/// code block runs to its closing fence (or the end of the note).
List<MdBlock> parseMarkdown(String text) {
  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final blocks = <MdBlock>[];
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    // Fenced code block.
    if (line.trimLeft().startsWith('```')) {
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      if (i < lines.length) i++; // the closing fence
      blocks.add(MdBlock(MdBlockKind.codeBlock, rawText: code.join('\n')));
      continue;
    }
    final heading = _headingRe.firstMatch(line);
    if (heading != null) {
      blocks.add(
        MdBlock(
          MdBlockKind.heading,
          level: heading.group(1)!.length,
          spans: parseInline(heading.group(2)!),
        ),
      );
      i++;
      continue;
    }
    if (_ruleRe.hasMatch(line)) {
      blocks.add(const MdBlock(MdBlockKind.rule));
      i++;
      continue;
    }
    if (_checkRe.hasMatch(line)) {
      final items = <MdCheckItem>[];
      while (i < lines.length) {
        final m = _checkRe.firstMatch(lines[i]);
        if (m == null) break;
        items.add(
          MdCheckItem(
            checked: m.group(1)!.toLowerCase() == 'x',
            spans: parseInline(m.group(2)!),
          ),
        );
        i++;
      }
      blocks.add(MdBlock(MdBlockKind.checklist, checkItems: items));
      continue;
    }
    if (_bulletRe.hasMatch(line)) {
      final items = <List<MdSpan>>[];
      while (i < lines.length &&
          _bulletRe.hasMatch(lines[i]) &&
          !_checkRe.hasMatch(lines[i])) {
        items.add(parseInline(_bulletRe.firstMatch(lines[i])!.group(1)!));
        i++;
      }
      blocks.add(MdBlock(MdBlockKind.bulletList, items: items));
      continue;
    }
    if (_numberedRe.hasMatch(line)) {
      final items = <List<MdSpan>>[];
      var start = 1;
      var first = true;
      while (i < lines.length) {
        final m = _numberedRe.firstMatch(lines[i]);
        if (m == null) break;
        if (first) {
          start = int.tryParse(m.group(1)!) ?? 1;
          first = false;
        }
        items.add(parseInline(m.group(2)!));
        i++;
      }
      blocks.add(
        MdBlock(MdBlockKind.numberedList, items: items, startNumber: start),
      );
      continue;
    }
    if (_quoteRe.hasMatch(line)) {
      final quoteLines = <List<MdSpan>>[];
      while (i < lines.length) {
        final m = _quoteRe.firstMatch(lines[i]);
        if (m == null) break;
        quoteLines.add(parseInline(m.group(1)!));
        i++;
      }
      blocks.add(MdBlock(MdBlockKind.quote, quoteLines: quoteLines));
      continue;
    }
    // Paragraph: consecutive plain lines join with a space, the way
    // Markdown renders them as one flowing paragraph.
    final parts = <String>[];
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !_headingRe.hasMatch(lines[i]) &&
        !_bulletRe.hasMatch(lines[i]) &&
        !_numberedRe.hasMatch(lines[i]) &&
        !_quoteRe.hasMatch(lines[i]) &&
        !_ruleRe.hasMatch(lines[i]) &&
        !lines[i].trimLeft().startsWith('```')) {
      parts.add(lines[i].trim());
      i++;
    }
    blocks.add(
      MdBlock(MdBlockKind.paragraph, spans: parseInline(parts.join(' '))),
    );
  }
  return blocks;
}

/// A plain-text rendering of a note body: markers removed, structure
/// kept with simple characters (bullets, numbers, `[x]` / `[ ]` for
/// checklists, `>` dropped on quotes). This is what the CLI's
/// `render` command prints.
String renderMarkdownPlain(String text) {
  final out = <String>[];
  String spansText(List<MdSpan> spans) => spans.map((s) => s.text).join();
  for (final block in parseMarkdown(text)) {
    switch (block.kind) {
      case MdBlockKind.heading:
      case MdBlockKind.paragraph:
        out.add(spansText(block.spans));
      case MdBlockKind.bulletList:
        for (final item in block.items) {
          out.add('• ${spansText(item)}');
        }
      case MdBlockKind.numberedList:
        var n = block.startNumber;
        for (final item in block.items) {
          out.add('${n++}. ${spansText(item)}');
        }
      case MdBlockKind.checklist:
        for (final item in block.checkItems) {
          out.add('${item.checked ? '[x]' : '[ ]'} ${spansText(item.spans)}');
        }
      case MdBlockKind.codeBlock:
        out.add(block.rawText);
      case MdBlockKind.quote:
        for (final line in block.quoteLines) {
          out.add(spansText(line));
        }
      case MdBlockKind.rule:
        out.add('---');
    }
    out.add('');
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

// -- Formatting operations ----------------------------------------------

/// The formatting operations behind the editor toolbar and the CLI's
/// `format` command.
enum MdFormat { bold, italic, code, heading, link, quote, checklist }

/// The result of a formatting operation: the new text plus the
/// selection (start/end offsets) the editor should show afterwards.
typedef MdEdit = ({String text, int start, int end});

/// Expands a selection out to whole lines.
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

/// Applies [format] to the selected part of [text] (or, with a
/// collapsed selection, at the cursor). Wrap-style formats toggle:
/// applying bold to text that is already bold removes the markers.
MdEdit applyMarkdownFormat(
  String text,
  int selStart,
  int selEnd,
  MdFormat format,
) {
  var start = selStart.clamp(0, text.length);
  var end = selEnd.clamp(0, text.length);
  if (end < start) {
    final tmp = start;
    start = end;
    end = tmp;
  }
  switch (format) {
    case MdFormat.bold:
      return _wrap(text, start, end, '**');
    case MdFormat.italic:
      return _wrap(text, start, end, '*');
    case MdFormat.code:
      final selected = text.substring(start, end);
      if (selected.contains('\n')) {
        // Fenced block around whole lines.
        final (s, e) = _wholeLines(text, start, end);
        final segment = text.substring(s, e);
        if (segment.startsWith('```')) {
          final stripped = segment
              .replaceFirst(RegExp(r'^```[^\n]*\n?'), '')
              .replaceFirst(RegExp(r'\n?```$'), '');
          return (
            text: text.replaceRange(s, e, stripped),
            start: s,
            end: s + stripped.length,
          );
        }
        final fenced = '```\n$segment\n```';
        return (
          text: text.replaceRange(s, e, fenced),
          start: s,
          end: s + fenced.length,
        );
      }
      return _wrap(text, start, end, '`');
    case MdFormat.link:
      final selected = text.substring(start, end);
      if (selected.startsWith('[') && selected.contains('](')) {
        // Already a link: unwrap to its label.
        final plain = inlinePlainText(selected);
        return (
          text: text.replaceRange(start, end, plain),
          start: start,
          end: start + plain.length,
        );
      }
      final linked = '[$selected](url)';
      // Select the url placeholder so it can be typed over.
      final urlStart = start + selected.length + 3;
      return (
        text: text.replaceRange(start, end, linked),
        start: urlStart,
        end: urlStart + 3,
      );
    case MdFormat.heading:
      return _linePrefix(
        text,
        start,
        end,
        toggle: (line) {
          final m = _headingRe.firstMatch(line);
          if (m != null) return m.group(2)!;
          return '# $line';
        },
        isPrefixed: (line) => _headingRe.hasMatch(line),
      );
    case MdFormat.quote:
      return _linePrefix(
        text,
        start,
        end,
        toggle: (line) => line.startsWith('> ') ? line.substring(2) : '> $line',
        isPrefixed: (line) => line.startsWith('> '),
      );
    case MdFormat.checklist:
      return _linePrefix(
        text,
        start,
        end,
        toggle: (line) {
          final check = _checkRe.firstMatch(line);
          if (check != null) return check.group(2)!;
          final bullet = _bulletRe.firstMatch(line);
          if (bullet != null) return '- [ ] ${bullet.group(1)!}';
          if (line.trim().isEmpty) return line;
          return '- [ ] $line';
        },
        isPrefixed: (line) => _checkRe.hasMatch(line),
      );
  }
}

/// Wrap-style toggle (`**`, `*`, backtick): wraps the selection, or
/// unwraps it when it is already wrapped — checked both inside the
/// selection (`**text**` fully selected) and around it (the cursor's
/// word selected inside existing markers).
MdEdit _wrap(String text, int start, int end, String marker) {
  final selected = text.substring(start, end);
  final m = marker.length;
  if (selected.length >= 2 * m &&
      selected.startsWith(marker) &&
      selected.endsWith(marker)) {
    final inner = selected.substring(m, selected.length - m);
    return (
      text: text.replaceRange(start, end, inner),
      start: start,
      end: start + inner.length,
    );
  }
  if (start >= m &&
      end + m <= text.length &&
      text.substring(start - m, start) == marker &&
      text.substring(end, end + m) == marker) {
    return (
      text: text
          .replaceRange(end, end + m, '')
          .replaceRange(start - m, start, ''),
      start: start - m,
      end: end - m,
    );
  }
  final wrapped = '$marker$selected$marker';
  // With no selection the cursor lands between the markers, ready to
  // type the marked text; with a selection it stays selected.
  return (
    text: text.replaceRange(start, end, wrapped),
    start: selected.isEmpty ? start + m : start,
    end: selected.isEmpty ? start + m : start + wrapped.length,
  );
}

/// Line-style toggle (heading, quote, checklist): when every non-blank
/// touched line already carries the mark, [toggle] is applied per line
/// (each format's toggle removes its own mark); otherwise it is
/// applied per line too — the per-line toggle adds the mark where it
/// is missing, which is what a mixed selection needs. Blank lines are
/// left alone.
MdEdit _linePrefix(
  String text,
  int start,
  int end, {
  required String Function(String line) toggle,
  required bool Function(String line) isPrefixed,
}) {
  final (s, e) = _wholeLines(text, start, end);
  final segment = text.substring(s, e);
  final lines = segment.split('\n');
  final out = lines
      .map((line) => line.trim().isEmpty ? line : toggle(line))
      .join('\n');
  return (text: text.replaceRange(s, e, out), start: s, end: s + out.length);
}

/// English name of a format, for the CLI (`format ID bold`) and help.
MdFormat? mdFormatFromName(String name) => switch (name.toLowerCase()) {
  'bold' => MdFormat.bold,
  'italic' => MdFormat.italic,
  'code' => MdFormat.code,
  'heading' => MdFormat.heading,
  'link' => MdFormat.link,
  'quote' => MdFormat.quote,
  'checklist' => MdFormat.checklist,
  _ => null,
};
