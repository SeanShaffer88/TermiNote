// Unit tests for Markdown support: inline/block parsing, the plain
// rendering, and the formatting operations shared by the editor
// toolbar and the CLI `format` command.
import 'package:flutter_test/flutter_test.dart';
import 'package:terminote/markdown.dart';

void main() {
  group('parseInline', () {
    test('plain text is one plain span', () {
      expect(parseInline('hello'), const <MdSpan>[MdSpan('hello')]);
    });

    test('bold, italic, code, strike and link are recognised', () {
      expect(parseInline('a **bold** b'), const <MdSpan>[
        MdSpan('a '),
        MdSpan('bold', bold: true),
        MdSpan(' b'),
      ]);
      expect(parseInline('*soft*'), const <MdSpan>[
        MdSpan('soft', italic: true),
      ]);
      expect(parseInline('run `ls -la` now'), const <MdSpan>[
        MdSpan('run '),
        MdSpan('ls -la', code: true),
        MdSpan(' now'),
      ]);
      expect(parseInline('~~gone~~'), const <MdSpan>[
        MdSpan('gone', strike: true),
      ]);
      expect(parseInline('[site](https://example.com)'), const <MdSpan>[
        MdSpan('site', linkUrl: 'https://example.com'),
      ]);
    });

    test('marks nest and combine', () {
      expect(parseInline('***both***'), const <MdSpan>[
        MdSpan('both', bold: true, italic: true),
      ]);
      expect(parseInline('**a *b* c**'), const <MdSpan>[
        MdSpan('a ', bold: true),
        MdSpan('b', bold: true, italic: true),
        MdSpan(' c', bold: true),
      ]);
    });

    test('unclosed markers and snake_case stay literal', () {
      expect(parseInline('a **open'), const <MdSpan>[MdSpan('a **open')]);
      expect(parseInline('some_var_name'), const <MdSpan>[
        MdSpan('some_var_name'),
      ]);
      expect(parseInline('a * b'), const <MdSpan>[MdSpan('a * b')]);
    });

    test('code contents are literal', () {
      expect(parseInline('`**not bold**`'), const <MdSpan>[
        MdSpan('**not bold**', code: true),
      ]);
    });
  });

  group('parseMarkdown', () {
    test('headings carry their level and spans', () {
      final blocks = parseMarkdown('# Top\n\n### Sub **x**');
      expect(blocks, hasLength(2));
      expect(blocks[0].kind, MdBlockKind.heading);
      expect(blocks[0].level, 1);
      expect(blocks[1].level, 3);
      expect(blocks[1].spans.last, const MdSpan('x', bold: true));
    });

    test('paragraph lines join; lists group', () {
      final blocks = parseMarkdown(
        'one\ntwo\n\n- a\n- b\n\n1. first\n2. second',
      );
      expect(blocks.map((b) => b.kind), <MdBlockKind>[
        MdBlockKind.paragraph,
        MdBlockKind.bulletList,
        MdBlockKind.numberedList,
      ]);
      expect(blocks[1].items, hasLength(2));
      expect(blocks[2].startNumber, 1);
    });

    test('checklist keeps tick state and stays out of bullet lists', () {
      final blocks = parseMarkdown('- [ ] todo\n- [x] done\n- plain');
      expect(blocks.map((b) => b.kind), <MdBlockKind>[
        MdBlockKind.checklist,
        MdBlockKind.bulletList,
      ]);
      expect(blocks[0].checkItems.map((i) => i.checked), <bool>[false, true]);
    });

    test('fenced code, quote and rule', () {
      final blocks = parseMarkdown(
        '```\n**raw**\n```\n\n> quoted\n> lines\n\n---',
      );
      expect(blocks.map((b) => b.kind), <MdBlockKind>[
        MdBlockKind.codeBlock,
        MdBlockKind.quote,
        MdBlockKind.rule,
      ]);
      expect(blocks[0].rawText, '**raw**');
      expect(blocks[1].quoteLines, hasLength(2));
    });

    test('an unclosed fence runs to the end without losing text', () {
      final blocks = parseMarkdown('```\ncode\nmore');
      expect(blocks.single.kind, MdBlockKind.codeBlock);
      expect(blocks.single.rawText, 'code\nmore');
    });
  });

  group('renderMarkdownPlain', () {
    test('markers are removed and structure is kept', () {
      const source =
          '# Title\n\nSome **bold** and [a link](https://x.y).\n\n'
          '- [ ] task\n- [x] done\n\n- one\n- two\n\n> a quote';
      expect(
        renderMarkdownPlain(source),
        'Title\n\nSome bold and a link.\n\n[ ] task\n[x] done\n\n'
        '• one\n• two\n\na quote',
      );
    });
  });

  group('applyMarkdownFormat', () {
    test('bold wraps and unwraps a selection', () {
      final wrapped = applyMarkdownFormat('hello world', 0, 5, MdFormat.bold);
      expect(wrapped.text, '**hello** world');
      expect((wrapped.start, wrapped.end), (0, 9));
      final unwrapped = applyMarkdownFormat(wrapped.text, 0, 9, MdFormat.bold);
      expect(unwrapped.text, 'hello world');
    });

    test('bold unwraps when the selection sits inside markers', () {
      final result = applyMarkdownFormat('**hello**', 2, 7, MdFormat.bold);
      expect(result.text, 'hello');
    });

    test('bold with no selection leaves the cursor between markers', () {
      final result = applyMarkdownFormat('ab', 1, 1, MdFormat.bold);
      expect(result.text, 'a****b');
      expect((result.start, result.end), (3, 3));
    });

    test('code is inline for one line and a fence for many', () {
      expect(
        applyMarkdownFormat('run ls now', 4, 6, MdFormat.code).text,
        'run `ls` now',
      );
      expect(
        applyMarkdownFormat('one\ntwo', 0, 7, MdFormat.code).text,
        '```\none\ntwo\n```',
      );
    });

    test('heading toggles per touched line', () {
      final on = applyMarkdownFormat('title\nbody', 0, 5, MdFormat.heading);
      expect(on.text, '# title\nbody');
      final off = applyMarkdownFormat(on.text, 0, 7, MdFormat.heading);
      expect(off.text, 'title\nbody');
    });

    test('quote and checklist toggle per line; checklist eats bullets', () {
      final quoted = applyMarkdownFormat('a\nb', 0, 3, MdFormat.quote);
      expect(quoted.text, '> a\n> b');
      expect(
        applyMarkdownFormat(quoted.text, 0, 5, MdFormat.quote).text,
        'a\nb',
      );
      final checked = applyMarkdownFormat(
        '- milk\neggs',
        0,
        11,
        MdFormat.checklist,
      );
      expect(checked.text, '- [ ] milk\n- [ ] eggs');
      expect(
        applyMarkdownFormat(checked.text, 0, 17, MdFormat.checklist).text,
        'milk\neggs',
      );
    });

    test('link wraps with the url selected, and unwraps to the label', () {
      final linked = applyMarkdownFormat('see the site', 8, 12, MdFormat.link);
      expect(linked.text, 'see the [site](url)');
      expect(linked.text.substring(linked.start, linked.end), 'url');
      final plain = applyMarkdownFormat(linked.text, 8, 20, MdFormat.link);
      expect(plain.text, 'see the site');
    });

    test('out-of-range selections are clamped, not fatal', () {
      final result = applyMarkdownFormat('abc', -5, 99, MdFormat.italic);
      expect(result.text, '*abc*');
    });
  });

  group('mdFormatFromName', () {
    test('names map, unknown is null', () {
      expect(mdFormatFromName('BOLD'), MdFormat.bold);
      expect(mdFormatFromName('checklist'), MdFormat.checklist);
      expect(mdFormatFromName('nope'), isNull);
    });
  });
}
