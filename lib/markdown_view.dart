/// The editor's Markdown preview: paints a parsed note body (see
/// markdown.dart) in the app's terminal theme — white text on the card
/// surface, red for links and checklist marks, code on a lighter chip.
/// Read-only; editing happens in the plain text field, and the
/// Edit/Preview switch in the editor swaps between the two.
library;

import 'package:flutter/material.dart';

import 'markdown.dart';
import 'theme.dart';

/// A scrollable, read-only rendering of [text] as Markdown.
class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.text, required this.fontSize});

  /// The note body, exactly as typed (Markdown source).
  final String text;

  /// Base font size, following the editor's A− / A+ setting.
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final blocks = parseMarkdown(text);
    if (blocks.isEmpty) {
      return Text(
        'Nothing to preview yet.',
        style: TextStyle(color: kDim, fontSize: fontSize),
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < blocks.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(height: 10),
            _blockWidget(blocks[i]),
          ],
        ],
      ),
    );
  }

  TextStyle _base({double? size, FontWeight? weight}) => TextStyle(
    color: Colors.white,
    fontSize: size ?? fontSize,
    fontWeight: weight,
    height: 1.5,
  );

  InlineSpan _spanWidget(MdSpan span, [TextStyle? baseStyle]) {
    var style = baseStyle ?? _base();
    if (span.bold) style = style.copyWith(fontWeight: FontWeight.bold);
    if (span.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (span.strike) {
      style = style.copyWith(decoration: TextDecoration.lineThrough);
    }
    if (span.code) {
      style = style.copyWith(backgroundColor: kSurfaceAlt, color: kAccentText);
    }
    if (span.linkUrl != null) {
      style = style.copyWith(
        color: kAccentText,
        decoration: TextDecoration.underline,
        decorationColor: kAccentText,
      );
    }
    return TextSpan(text: spanPlainText(span), style: style);
  }

  Widget _rich(List<MdSpan> spans, {TextStyle? style}) {
    return Text.rich(
      TextSpan(
        style: style ?? _base(),
        children: <InlineSpan>[for (final s in spans) _spanWidget(s, style)],
      ),
    );
  }

  Widget _blockWidget(MdBlock block) {
    switch (block.kind) {
      case MdBlockKind.heading:
        final scale = switch (block.level) {
          1 => 1.7,
          2 => 1.4,
          3 => 1.2,
          _ => 1.05,
        };
        return _rich(
          block.spans,
          style: _base(size: fontSize * scale, weight: FontWeight.bold),
        );
      case MdBlockKind.paragraph:
        return _rich(block.spans);
      case MdBlockKind.bulletList:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final item in block.items)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('•  ', style: _base()),
                  Expanded(child: _rich(item)),
                ],
              ),
          ],
        );
      case MdBlockKind.numberedList:
        var n = block.startNumber;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final item in block.items)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('${n++}.  ', style: _base()),
                  Expanded(child: _rich(item)),
                ],
              ),
          ],
        );
      case MdBlockKind.checklist:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final item in block.checkItems)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.checked ? '☑  ' : '☐  ',
                    style: _base().copyWith(color: kAccentText),
                  ),
                  Expanded(
                    child: _rich(
                      item.spans,
                      style: item.checked
                          ? _base().copyWith(
                              color: kDim,
                              decoration: TextDecoration.lineThrough,
                            )
                          : null,
                    ),
                  ),
                ],
              ),
          ],
        );
      case MdBlockKind.codeBlock:
        return Container(
          decoration: BoxDecoration(
            color: kSurfaceAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            block.rawText,
            style: TextStyle(
              color: Colors.white,
              fontSize: fontSize - 1,
              height: 1.5,
            ),
          ),
        );
      case MdBlockKind.quote:
        return Container(
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: kAccent, width: 3)),
          ),
          padding: const EdgeInsets.only(left: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final line in block.quoteLines) _rich(line),
            ],
          ),
        );
      case MdBlockKind.rule:
        return const Divider(color: Color(0xFF4A4A4A), height: 2);
      case MdBlockKind.table:
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: kBorder),
            children: <TableRow>[
              TableRow(
                decoration: const BoxDecoration(color: kSurfaceAlt),
                children: <Widget>[
                  for (final cell in block.headerCells)
                    _tableCell(cell, header: true),
                ],
              ),
              for (final row in block.tableRows)
                TableRow(
                  children: <Widget>[
                    for (final cell in row) _tableCell(cell, header: false),
                  ],
                ),
            ],
          ),
        );
    }
  }

  Widget _tableCell(List<MdSpan> spans, {required bool header}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: _rich(
        spans,
        style: _base(
          weight: header ? FontWeight.bold : FontWeight.normal,
        ).copyWith(height: 1.4),
      ),
    );
  }
}
