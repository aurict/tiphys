// Home screen card "Oyun Modu" (id gameMode): dark glass tile like the Claude one. Status, the song on one line and a
// big button that starts/stops the mode. Hidden while no host has the game-mode feature.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import 'gamemode_data.dart';

class GameModeHomeCard extends ConsumerStatefulWidget {
  const GameModeHomeCard({super.key});
  @override
  ConsumerState<GameModeHomeCard> createState() => _GameModeHomeCardState();
}

class _GameModeHomeCardState extends ConsumerState<GameModeHomeCard> {
  bool _busy = false;

  Future<void> _toggle(String hostId, bool running) async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(gameModeProvider(hostId).notifier).setRunning(!running);
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final target = ref.watch(gameModeTargetProvider).value;
    if (target == null) return const SizedBox.shrink();
    final host = target.host;
    final status = target.configured ? ref.watch(gameModeProvider(host.id)).value : null;
    final route = '/gamemode?host=${Uri.encodeQueryComponent(host.id)}';
    final running = status?.running ?? false;
    final truck = status?.truck;
    final music = status?.music;
    final String headline;
    if (!target.configured) {
      headline = l.gmCardSetup;
    } else if (status == null) {
      headline = '–';
    } else if (!running) {
      headline = l.gmOff;
    } else if (truck?.driving == true && truck?.from != null && truck?.to != null) {
      headline = l.gmDriving(truck!.from!, truck.to!);
    } else if (truck?.driving == true && truck?.speedKmh != null) {
      headline = l.gmDrivingSpeed('${truck!.speedKmh}');
    } else {
      headline = l.gmOnAt(host.name);
    }
    final song = running && music != null && music.title.isNotEmpty ? (music.artist.isEmpty ? music.title : '${music.title} · ${music.artist}') : null;
    return TCard(
      height: MediaQuery.textScalerOf(context).scale(112),
      color: t.claudeTile,
      borderColor: t.claudeTileBorder,
      padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
      onTap: () => context.push(route),
      semanticLabel: l.gmTitle,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.gamepad2, size: 16, color: t.claudeTileSubtext),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l.gmTitle,
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: t.claudeTileText),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      headline,
                      style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: t.claudeTileText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (song != null)
                      Text(
                        song,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: t.claudeTileSubtext),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (target.configured && status != null) ...[
            const SizedBox(width: 12),
            Semantics(
              button: true,
              label: running ? l.gmStop : l.gmStart,
              child: Material(
                color: running ? t.danger : Colors.white,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: _busy ? null : () => _toggle(host.id, running),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: _busy
                        ? const Padding(padding: EdgeInsets.all(22), child: CircularProgressIndicator(strokeWidth: 2.4))
                        : Icon(running ? LucideIcons.square : LucideIcons.play, size: 26, color: running ? Colors.white : const Color(0xFF1E1B4B)),
                  ),
                ),
              ),
            ),
          ] else if (!target.configured)
            Icon(LucideIcons.chevronRight, color: t.claudeTileSubtext),
        ],
      ),
    );
  }
}
