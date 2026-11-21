// Texts of the screen modes that depend on agent codes and keys (PLAN.md §20, contract section; §19 for Game mode).
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';

String screenErrorText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) => switch (code) {
  'agent.screen.noSource' || 'agent.gamemode.noSource' => l.smErrNoSource,
  'agent.screen.noDisplay' || 'agent.gamemode.noDisplay' => l.gmErrNoDisplay,
  'agent.screen.startFailed' || 'agent.gamemode.startFailed' => l.gmErrStartFailed,
  'agent.screen.bindTaken' => l.smErrBindTaken(bindText('${params['bind'] ?? ''}')),
  'agent.screen.badLayout' => l.smErrBadLayout,
  'agent.screen.notFocus' => l.smErrNotFocus,
  'agent.screen.notRunning' => l.smErrNotRunning,
  'agent.screen.noArt' || 'agent.gamemode.noArt' => l.gmErrNoArt,
  'agent.gamemode.noGame' => l.gmPluginNoGame,
  'agent.gamemode.pluginDownloadFailed' => l.gmErrPluginDownloadFailed,
  'agent.gamemode.pluginHashMismatch' => l.gmErrPluginHashMismatch,
  'agent.gamemode.pluginBadArchive' => l.gmErrPluginBadArchive,
  'app.screen.needsUpdate' => l.smNeedsUpdate,
  _ => '${l.commonError} ($code)',
};

String screenModeName(AppLocalizations l, String? mode) => switch (mode) {
  'work' => l.smModeWork,
  'focus' => l.smModeFocus,
  'game' => l.smModeGame,
  'sleep' => l.smModeSleep,
  _ => l.smTitle,
};

String screenModeHint(AppLocalizations l, String mode) => switch (mode) {
  'work' => l.smModeWorkHint,
  'focus' => l.smModeFocusHint,
  'sleep' => l.smModeSleepHint,
  _ => l.smModeGameHint,
};

IconData screenModeIcon(String? mode) => switch (mode) {
  'work' => LucideIcons.codeXml,
  'focus' => LucideIcons.target,
  'game' => LucideIcons.gamepad2,
  'sleep' => LucideIcons.moonStar,
  _ => LucideIcons.monitor,
};

/// Hyprland's "SUPER,grave" as people read it: "Super + `".
String bindText(String bind) {
  final i = bind.indexOf(',');
  if (i < 0) return bind;
  final mods = bind.substring(0, i).split(RegExp(r'[ _]')).where((m) => m.isNotEmpty).map((m) => m[0] + m.substring(1).toLowerCase());
  final key = bind.substring(i + 1);
  final k = switch (key.toLowerCase()) {
    'grave' => '`',
    'space' => 'Space',
    'return' => 'Enter',
    _ => key.length == 1 ? key.toUpperCase() : key,
  };
  return [...mods, k].join(' + ');
}

/// `screen.focus.phase {phase, from, round, cause}` → title and body (the task is never in it).
(String, String) focusPhaseNotice(AppLocalizations l, Map<String, dynamic> p) {
  final round = (p['round'] as num?)?.toInt() ?? 0;
  final title = switch ('${p['phase']}') {
    'focus' => l.smNoticeFocus(round),
    'short' => l.smNoticeShort,
    'long' => l.smNoticeLong,
    _ => l.smNoticeIdle,
  };
  final body = switch ('${p['cause']}') {
    'timer' => '${p['phase']}' == 'focus' ? l.smNoticeBreakOver : l.smNoticeRoundDone(round),
    'stop' => l.smNoticeStopped,
    _ => l.smNoticeAction,
  };
  return (title, body);
}
