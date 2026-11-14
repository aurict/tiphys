// Claude cevaplarının Markdown görünümü (GFM: tablo, üstü çizili, görev listesi, otomatik bağlantı).
// Kod blokları dil etiketi + kopyala düğmesiyle, tablolar yatay kaydırmalı; renkler tema token'larından.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';

const _mono = 'JetBrainsMono';

class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown(this.data, {super.key});
  final String data;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final body = TextStyle(fontSize: 15, height: 1.45, color: t.text);
    final sheet = MarkdownStyleSheet(
      p: body,
      a: body.copyWith(color: t.accent, decoration: TextDecoration.underline, decorationColor: t.accent),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      em: const TextStyle(fontStyle: FontStyle.italic),
      del: TextStyle(decoration: TextDecoration.lineThrough, color: t.textSecondary),
      h1: body.copyWith(fontSize: 20, fontWeight: FontWeight.w800, height: 1.3),
      h2: body.copyWith(fontSize: 18, fontWeight: FontWeight.w700, height: 1.3),
      h3: body.copyWith(fontSize: 16, fontWeight: FontWeight.w700, height: 1.3),
      h4: body.copyWith(fontWeight: FontWeight.w700),
      h5: body.copyWith(fontWeight: FontWeight.w700),
      h6: body.copyWith(fontWeight: FontWeight.w700, color: t.textSecondary),
      h1Padding: const EdgeInsets.only(top: 6),
      h2Padding: const EdgeInsets.only(top: 6),
      h3Padding: const EdgeInsets.only(top: 4),
      blockSpacing: 10,
      listIndent: 22,
      listBullet: body.copyWith(color: t.textSecondary),
      listBulletPadding: const EdgeInsets.only(right: 6),
      checkbox: body.copyWith(color: t.accent),
      // Satır içi kod: `böyle`. Ligatürler kapalı (!= → ≠ olmasın).
      code: TextStyle(
        fontFamily: _mono,
        fontSize: 13,
        color: t.text,
        // açık temada sayfa zemini chipBackground ile aynı renk: ayrışsın diye ayraç tonu
        backgroundColor: t.isDark ? t.chipBackground : t.separator,
        fontFeatures: const [FontFeature.disable('calt'), FontFeature.disable('liga')],
      ),
      blockquote: body.copyWith(color: t.textSecondary),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      blockquoteDecoration: BoxDecoration(border: Border(left: BorderSide(color: t.accent, width: 3))),
      horizontalRuleDecoration: BoxDecoration(border: Border(top: BorderSide(color: t.separator))),
      tableHead: body.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
      tableBody: body.copyWith(fontSize: 14),
      tableBorder: TableBorder.all(color: t.separator, width: 1, borderRadius: BorderRadius.circular(8)),
      tableHeadAlign: TextAlign.start,
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      // Doğal genişlik: dar ekranda sütunlar ezilmez, tablo yatay kaydırılır.
      tableColumnWidth: const IntrinsicColumnWidth(),
    );
    return MarkdownBody(
      data: data,
      selectable: true,
      styleSheet: sheet,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      builders: {'pre': _CodeBlockBuilder()},
      onTapLink: (text, href, title) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
  }
}

/// ```dil … ``` blokları: başlıkta dil adı + kopyala, içerik yatay kaydırmalı ve seçilebilir.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    final cls = element.children?.whereType<md.Element>().firstOrNull?.attributes['class'] ?? '';
    final lang = cls.startsWith('language-') ? cls.substring('language-'.length) : '';
    return CodeBlock(code: code, language: lang);
  }
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, this.language = ''});
  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final l = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      // açık temada beyaz kart (sayfa zemini gri), koyu temada yarı saydam yüzey
      decoration: BoxDecoration(
        color: t.isDark ? t.chipBackground : t.card,
        borderRadius: BorderRadius.circular(12),
        border: t.isDark ? null : Border.all(color: t.separator),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(children: [
            Expanded(child: Text(language, style: TextStyle(fontSize: 12, color: t.textSecondary, fontFamily: _mono))),
            IconButton(
              tooltip: l.commonCopy,
              visualDensity: VisualDensity.compact,
              icon: Icon(LucideIcons.copy, size: 16, color: t.textSecondary),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                toast(context, l.commonCopied);
              },
            ),
          ]),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: SelectableText(
            code,
            style: const TextStyle(
              fontFamily: _mono,
              fontSize: 12.5,
              height: 1.4,
              fontFeatures: [FontFeature.disable('calt'), FontFeature.disable('liga')],
            ),
          ),
        ),
      ]),
    );
  }
}
