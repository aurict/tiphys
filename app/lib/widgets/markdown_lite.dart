// Small markdown renderer (for Grafana text panels): headings, lists, **bold**, *italic*,
// `code` and [link](url). HTML tags are stripped.
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class MarkdownLite extends StatelessWidget {
  const MarkdownLite(this.source, {super.key, this.html = false});
  final String source;
  final bool html;

  static final _inline = RegExp(r'(\*\*[^*]+\*\*|\*[^*\s][^*]*\*|`[^`]+`|\[[^\]]+\]\([^)]+\))');

  List<InlineSpan> _spans(String text, TextStyle base, TiphysTokens t) {
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _inline.allMatches(text)) {
      if (m.start > last) out.add(TextSpan(text: text.substring(last, m.start)));
      final s = m[0]!;
      if (s.startsWith('**')) {
        out.add(TextSpan(text: s.substring(2, s.length - 2), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (s.startsWith('`')) {
        out.add(TextSpan(
          text: s.substring(1, s.length - 1),
          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: (base.fontSize ?? 14) - 1, backgroundColor: t.chipBackground),
        ));
      } else if (s.startsWith('[')) {
        out.add(TextSpan(text: s.substring(1, s.indexOf(']')), style: TextStyle(color: t.accent, fontWeight: FontWeight.w600)));
      } else {
        out.add(TextSpan(text: s.substring(1, s.length - 1), style: const TextStyle(fontStyle: FontStyle.italic)));
      }
      last = m.end;
    }
    if (last < text.length) out.add(TextSpan(text: text.substring(last)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    var text = source;
    if (html) {
      text = text
          .replaceAll(RegExp(r'<br\s*/?>|</p>|</div>|</li>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '- ')
          .replaceAll(RegExp(r'<[^>]+>'), '');
    }
    final base = TextStyle(fontSize: 14, height: 1.45, color: t.text);
    final blocks = <Widget>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 6));
        continue;
      }
      final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      final li = RegExp(r'^\s*(?:[-*+]|\d+\.)\s+(.*)$').firstMatch(line);
      if (h != null) {
        final size = switch (h[1]!.length) { 1 => 20.0, 2 => 17.0, _ => 15.0 };
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text.rich(TextSpan(children: _spans(h[2]!, base, t)), style: base.copyWith(fontSize: size, fontWeight: FontWeight.w800)),
        ));
      } else if (li != null) {
        blocks.add(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('•  ', style: base.copyWith(color: t.textSecondary)),
          Expanded(child: Text.rich(TextSpan(children: _spans(li[1]!, base, t)), style: base)),
        ]));
      } else {
        blocks.add(Text.rich(TextSpan(children: _spans(line, base, t)), style: base));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
  }
}
