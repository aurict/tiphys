// Henüz yapılmamış sekmeler için geçici ekran (her faz kendi ekranıyla değiştirir).
import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../theme/tokens.dart';
import '../widgets/floating_tab_bar.dart';
import '../widgets/surfaces.dart';

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({
    super.key,
    required this.tab,
    required this.phase,
    this.title,
  });
  final String tab;
  final int phase;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final name =
        title ??
        switch (tab) {
          'claude' => l.tabClaude,
          'terminal' => l.tabTerminal,
          'files' => l.tabFiles,
          _ => l.tabSystem,
        };
    return ListView(
      padding: EdgeInsets.fromLTRB(
        TiphysTokens.gutter,
        MediaQuery.paddingOf(context).top + 18,
        TiphysTokens.gutter,
        FloatingTabBar.height + FloatingTabBar.bottomGap + 24,
      ),
      children: [
        LargeTitleHeader(title: name),
        const SizedBox(height: 16),
        TCard(
          child: Text(
            l.comingInPhase(phase),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
