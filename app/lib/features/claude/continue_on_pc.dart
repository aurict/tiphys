// "Continue on the PC": the command that continues a Claude or agy conversation in a terminal on the PC. A live session
// that is still running is stopped first (two programs writing the same conversation would fork it).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../system/agent_providers.dart';

/// Single-quoted for a POSIX shell, exactly like the agent (`shq` in agent/src/agy/manager.ts).
String shellQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// `cd '<cwd>' && claude --resume <id>`: what the agent puts in a Claude summary's `resumeCommand`.
String claudeResumeCommand(String cwd, String sdkSessionId) => 'cd ${shellQuote(cwd)} && claude --resume $sdkSessionId';

/// `cd '<cwd>' && agy --conversation <id>`.
String agyResumeCommand(String cwd, String conversationId) => 'cd ${shellQuote(cwd)} && agy --conversation $conversationId';

/// Shows the command in a sheet. If [active] (the session is running or waiting) it first asks to stop it and runs [stop];
/// when stopping fails the error is shown and no command is offered. [command] null: "not available yet".
Future<void> continueOnPc(BuildContext context, {required String? command, required bool active, required Future<void> Function() stop}) async {
  final l = AppLocalizations.of(context);
  if (command == null) {
    toast(context, l.continuePcUnavailable);
    return;
  }
  if (active) {
    final ok = await confirmDialog(context, message: l.continuePcStopMessage, confirmLabel: l.continuePcStopAndShow, destructive: true);
    if (!ok || !context.mounted) return;
    try {
      await stop();
    } catch (e) {
      if (context.mounted) toast(context, agentErrorText(l, e));
      return;
    }
    if (!context.mounted) return;
  }
  await showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    builder: (_) => ContinueOnPcSheet(command: command),
  );
}

class ContinueOnPcSheet extends StatelessWidget {
  const ContinueOnPcSheet({super.key, required this.command});
  final String command;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(LucideIcons.monitor, color: t.accent),
                const SizedBox(width: 10),
                Expanded(child: Text(l.continuePcTitle, style: Theme.of(context).textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 8),
            Text(l.continuePcIntro, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: t.chipBackground, borderRadius: BorderRadius.circular(12)),
              child: SelectableText(
                command,
                style: TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.4, color: t.text),
              ),
            ),
            const SizedBox(height: 8),
            Text(l.continuePcHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (context.mounted) toast(context, l.continuePcCopied);
              },
              icon: const Icon(LucideIcons.copy, size: 18),
              label: Text(l.commonCopy),
            ),
          ],
        ),
      ),
    );
  }
}
