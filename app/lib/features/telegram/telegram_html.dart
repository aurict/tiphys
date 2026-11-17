// Telegram HTML subset (what the agent's render.ts produces): <b>, <i> and <a href="…">, with the entities
// &amp; &lt; &gt; &quot; and numeric ones. Only these tags are parsed; anything else (other tags, attributes, broken
// markup) is shown as plain text, so a hostile newsletter can't inject widgets or styles. Links are tappable only for
// http/https (opened with the phone's browser via openExternal).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/util/open_url.dart';

/// A run of text with the styles that apply to it. [href] is set only for a safe http(s) link.
class TgSpan {
  const TgSpan(this.text, {this.bold = false, this.italic = false, this.href});
  final String text;
  final bool bold;
  final bool italic;
  final String? href;

  @override
  bool operator ==(Object other) => other is TgSpan && other.text == text && other.bold == bold && other.italic == italic && other.href == href;
  @override
  int get hashCode => Object.hash(text, bold, italic, href);
  @override
  String toString() => 'TgSpan(${[text, if (bold) 'b', if (italic) 'i', if (href != null) href].join(', ')})';
}

final _entity = RegExp(r'&(amp|lt|gt|quot|#\d{1,7}|#[xX][0-9a-fA-F]{1,6});');
final _openA = RegExp(r'''^<a\s+href\s*=\s*(?:"([^"<>]*)"|'([^'<>]*)')\s*>''', caseSensitive: false);
final _simple = RegExp(r'^<(/?)([bi])>', caseSensitive: false);
final _closeA = RegExp(r'^</a>', caseSensitive: false);

String decodeTgEntities(String s) => s.replaceAllMapped(_entity, (m) {
      final e = m.group(1)!;
      switch (e) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
      }
      final code = e.startsWith('#x') || e.startsWith('#X') ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
      // Invalid code points (and NUL / surrogates) stay as written.
      if (code == null || code == 0 || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return m.group(0)!;
      return String.fromCharCode(code);
    });

/// http(s) URL with a host, otherwise null.
String? safeHttpUrl(String raw) {
  final u = Uri.tryParse(raw.trim());
  if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty) return null;
  return u.toString();
}

/// Parses the subset into spans. Adjacent text with the same style is merged.
List<TgSpan> parseTelegramHtml(String html) {
  final out = <TgSpan>[];
  var bold = 0, italic = 0;
  String? href;
  var inLink = false;
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    final text = decodeTgEntities(buf.toString());
    buf.clear();
    final span = TgSpan(text, bold: bold > 0, italic: italic > 0, href: inLink ? href : null);
    final last = out.isEmpty ? null : out.last;
    if (last != null && last.bold == span.bold && last.italic == span.italic && last.href == span.href) {
      out[out.length - 1] = TgSpan(last.text + span.text, bold: span.bold, italic: span.italic, href: span.href);
    } else {
      out.add(span);
    }
  }

  var i = 0;
  while (i < html.length) {
    final lt = html.indexOf('<', i);
    if (lt < 0) {
      buf.write(html.substring(i));
      break;
    }
    buf.write(html.substring(i, lt));
    final rest = html.substring(lt);
    final simple = _simple.firstMatch(rest);
    if (simple != null) {
      final closing = simple.group(1) == '/';
      final isBold = simple.group(2)!.toLowerCase() == 'b';
      final depth = isBold ? bold : italic;
      if (closing && depth == 0) {
        // Unmatched closing tag: plain text.
        buf.write(simple.group(0));
      } else {
        flush();
        final d = closing ? -1 : 1;
        if (isBold) {
          bold += d;
        } else {
          italic += d;
        }
      }
      i = lt + simple.group(0)!.length;
      continue;
    }
    final a = inLink ? null : _openA.firstMatch(rest);
    if (a != null) {
      flush();
      inLink = true;
      href = safeHttpUrl(decodeTgEntities(a.group(1) ?? a.group(2) ?? ''));
      i = lt + a.group(0)!.length;
      continue;
    }
    final ca = _closeA.firstMatch(rest);
    if (ca != null && inLink) {
      flush();
      inLink = false;
      href = null;
      i = lt + ca.group(0)!.length;
      continue;
    }
    // Any other "<": literal text.
    buf.write('<');
    i = lt + 1;
  }
  flush();
  return out;
}

/// Colours of the Telegram-like preview (Telegram's own light / dark chat palette).
class TgColors {
  const TgColors._(this.background, this.bubble, this.text, this.link, this.meta, this.header);
  final Color background;
  final Color bubble;
  final Color text;
  final Color link;
  final Color meta;
  final Color header;
  static const light = TgColors._(Color(0xFFCFDDE8), Color(0xFFFFFFFF), Color(0xFF000000), Color(0xFF2481CC), Color(0xFF8C9AA6), Color(0xFF517DA2));
  static const dark = TgColors._(Color(0xFF0E1621), Color(0xFF182533), Color(0xFFF5F5F5), Color(0xFF6AB3F3), Color(0xFF6D7F8F), Color(0xFF17212B));
  static TgColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// One message bubble: the parsed HTML with tappable links and a time stamp in the corner.
class TelegramMessage extends StatefulWidget {
  const TelegramMessage({super.key, required this.html, this.time});
  final String html;
  final String? time;
  @override
  State<TelegramMessage> createState() => _TelegramMessageState();
}

class _TelegramMessageState extends State<TelegramMessage> {
  final _recognizers = <TapGestureRecognizer>[];
  late List<TgSpan> _spans = parseTelegramHtml(widget.html);

  @override
  void didUpdateWidget(TelegramMessage old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _spans = parseTelegramHtml(widget.html);
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = TgColors.of(context);
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final children = <InlineSpan>[];
    for (final s in _spans) {
      TapGestureRecognizer? tap;
      if (s.href != null) {
        tap = TapGestureRecognizer()..onTap = () => openExternal(s.href!);
        _recognizers.add(tap);
      }
      children.add(TextSpan(
        text: s.text,
        style: TextStyle(fontWeight: s.bold ? FontWeight.w700 : null, fontStyle: s.italic ? FontStyle.italic : null, color: s.href != null ? c.link : null),
        recognizer: tap,
      ));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(right: 28, bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        decoration: BoxDecoration(
          color: c.bubble,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(14), topRight: Radius.circular(14), bottomRight: Radius.circular(14), bottomLeft: Radius.circular(4)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
          Text.rich(TextSpan(children: children), style: TextStyle(color: c.text, fontSize: 14.5, height: 1.35)),
          if (widget.time != null) Text(widget.time!, style: TextStyle(color: c.meta, fontSize: 11)),
        ]),
      ),
    );
  }
}

/// Telegram-like chat preview: the bot's name on top, one bubble per rendered part.
class TelegramPreview extends StatelessWidget {
  const TelegramPreview({super.key, required this.parts, this.botName, this.time});
  final List<String> parts;
  final String? botName;
  final String? time;

  @override
  Widget build(BuildContext context) {
    final c = TgColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: ColoredBox(
        color: c.background,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (botName != null)
            Container(
              color: c.header,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(children: [
                const CircleAvatar(radius: 14, backgroundColor: Color(0xFF4338CA), child: Text('T', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13))),
                const SizedBox(width: 10),
                Expanded(child: Text(botName!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final p in parts) TelegramMessage(html: p, time: time)]),
          ),
        ]),
      ),
    );
  }
}
