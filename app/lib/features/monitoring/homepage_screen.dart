// Homepage servisleri uygulama içinde: gruplar, durum, tarayıcıda açma; üstte gerçek Homepage butonu.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/util/open_url.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart' show SettingsPage;
import '../../widgets/surfaces.dart';
import 'providers.dart';

class HomepageScreen extends ConsumerWidget {
  const HomepageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final cfg = ref.watch(profileProvider.select((p) => p.integrations.homepage));
    final data = ref.watch(homepageProvider);

    Future<void> open(String url) async {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      if (cfg?.openInApp == true) {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      } else {
        await openExternal(url);
      }
    }

    List<Widget> group(Map g, int depth) {
      final services = (g['services'] as List).cast<Map>();
      final groups = (g['groups'] as List).cast<Map>();
      return [
        if (services.isNotEmpty)
          GroupedSection(title: depth == 0 ? '${g['name']}' : '${g['name']}', children: [
            for (final s in services)
              GroupedRow(
                title: '${s['name']}',
                subtitle: s['description'] as String?,
                icon: LucideIcons.globe,
                iconBackground: switch (s['status']) {
                  'up' => t.success,
                  'down' => t.danger,
                  _ => const Color(0xFF6C6C70),
                },
                trailingText: s['responseMs'] == null ? null : '${s['responseMs']} ms',
                external: true,
                onTap: s['href'] == null ? null : () => open('${s['href']}'),
              ),
          ]),
        for (final sub in groups) ...group(sub, depth + 1),
      ];
    }

    return SettingsPage(
      title: 'Homepage',
      actions: [IconButton(tooltip: l.commonRetry, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(homepageProvider))],
      children: [
        if (cfg != null)
          FilledButton.icon(
            onPressed: () => openExternal(cfg.browserUrl),
            icon: const Icon(LucideIcons.externalLink, size: 18),
            label: Text(l.homepageOpenReal),
          ),
        const SizedBox(height: 6),
        data.when(
          loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => TCard(child: Text(integrationErrorText(l, e))),
          data: (d) {
            final groups = (d['groups'] as List).cast<Map>();
            final all = <Map>[];
            void walk(Map g) {
              all.addAll((g['services'] as List).cast<Map>());
              (g['groups'] as List).cast<Map>().forEach(walk);
            }

            groups.forEach(walk);
            final down = all.where((s) => s['status'] == 'down').toList();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (down.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TCard(
                    borderColor: t.danger,
                    child: Text(l.homepageDown(down.map((s) => s['name']).join(', ')), style: TextStyle(color: t.danger, fontWeight: FontWeight.w600)),
                  ),
                ),
              for (final g in groups) ...group(g, 0),
            ]);
          },
        ),
      ],
    );
  }
}
