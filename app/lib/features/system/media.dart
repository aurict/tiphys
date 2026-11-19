// System › Media: remote for players on the PC (agent "desktop" feature: playerctl + wpctl). Cover, title,
// progress (seek by dragging), previous/play-pause/next, ±10 s, volume + mute, picker for multiple players.
// Status is polled every 2 s only while the screen is open and the app is in the foreground; the position
// advances locally in between.
// The "Now playing" card on the home screen also uses the provider here.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show claudeHostProvider;
import 'agent_providers.dart';

class MediaPlayer {
  MediaPlayer(Map j)
      : name = '${j['name']}',
        status = '${j['status']}',
        title = j['title'] as String?,
        artist = j['artist'] as String?,
        album = j['album'] as String?,
        length = (j['length'] as num?)?.toDouble(),
        position = (j['position'] as num?)?.toDouble(),
        artUrl = j['artUrl'] as String?,
        localArt = j['localArt'] == true,
        artId = j['artId'] as String?;
  final String name;
  final String status; // Playing | Paused | Stopped
  final String? title;
  final String? artist;
  final String? album;
  final double? length;
  final double? position;
  final String? artUrl;
  final bool localArt;
  final String? artId;
  bool get playing => status == 'Playing';
}

class MediaState {
  const MediaState({required this.players, required this.player, required this.volume, required this.fetchedAt});

  /// (name, status)
  final List<(String, String)> players;
  final MediaPlayer? player;

  /// (percent, muted); null if volume couldn't be read (no wpctl).
  final (int, bool)? volume;
  final DateTime fetchedAt;

  /// While playing, the time since the last query is added (so the bar advances smoothly within the 2 s interval).
  double? positionAt(DateTime now) {
    final p = player;
    if (p?.position == null) return null;
    var pos = p!.position!;
    if (p.playing) pos += now.difference(fetchedAt).inMilliseconds / 1000;
    final len = p.length;
    return len != null && len > 0 ? pos.clamp(0, len).toDouble() : pos;
  }
}

/// "firefox.instance_1_42" → "Firefox"
String playerLabel(String name) {
  final base = name.split('.').first;
  return switch (base.toLowerCase()) {
    'vlc' => 'VLC',
    'mpv' => 'mpv',
    'chromium' => 'Chromium',
    _ => base.isEmpty ? name : '${base[0].toUpperCase()}${base.substring(1)}',
  };
}

/// 75.4 → "1:15", 3725 → "1:02:05"
String mediaTime(double? s) {
  if (s == null) return '–:––';
  final d = Duration(seconds: s.floor());
  final m = (d.inMinutes % 60).toString().padLeft(d.inHours > 0 ? 2 : 1, '0');
  final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$sec' : '$m:$sec';
}

/// Media + volume (host, requested player). Refreshes every 2 s while the screen/card is visible and the app is in front.
final mediaProvider = FutureProvider.autoDispose.family<MediaState, (String, String?)>((ref, key) async {
  autoRefresh(ref, const Duration(seconds: 2));
  final (hostId, player) = key;
  final now = ref.read(clockProvider);
  return withAgent(ref, hostId, (c) async {
    final r = await Future.wait<Map<String, dynamic>?>([
      c.get('/v1/media', query: player == null ? null : {'player': player}),
      // Volume is separate: media is still shown if there's no wpctl.
      c.get('/v1/media/volume').then<Map<String, dynamic>?>((v) => v, onError: (_) => null),
    ]);
    final m = r[0]!, v = r[1];
    return MediaState(
      players: [for (final p in (m['players'] as List).cast<Map>()) ('${p['name']}', '${p['status']}')],
      player: m['player'] == null ? null : MediaPlayer(m['player'] as Map),
      volume: v == null ? null : ((v['percent'] as num).toInt(), v['muted'] == true),
      fetchedAt: now(),
    );
  });
});

/// Local cover (via the agent); refetched when the track changes (artId).
final mediaArtProvider = FutureProvider.autoDispose.family<Uint8List?, (String, String, String)>((ref, key) async {
  final (hostId, player, _) = key;
  return withAgent(ref, hostId, (c) => c.requestBytes('/v1/media/art', query: {'player': player}, timeout: const Duration(seconds: 15)));
});

/// Remote: the action goes to the agent, then the status is polled again.
Future<void> mediaAction(WidgetRef ref, BuildContext context, String hostId, String action, {String? player, double? seconds}) async {
  final l = AppLocalizations.of(context);
  try {
    await agentCall(ref, hostId, 'POST', '/v1/media/$action', {'player': ?player, 'seconds': ?seconds});
  } catch (e) {
    if (context.mounted) toast(context, agentErrorText(l, e));
  }
  ref.invalidate(mediaProvider);
}

class MediaScreen extends ConsumerStatefulWidget {
  const MediaScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends ConsumerState<MediaScreen> {
  String? _player;
  double? _seekDrag;
  double? _volDrag;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Advance the position bar once a second (only redrawn while playing).
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(mediaProvider((widget.hostId, _player))).value?.player?.playing == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _act(String action, {double? seconds}) {
    final p = ref.read(mediaProvider((widget.hostId, _player))).value?.player?.name;
    return mediaAction(ref, context, widget.hostId, action, player: p, seconds: seconds);
  }

  Future<void> _volume({int? percent, bool? muted}) async {
    final l = AppLocalizations.of(context);
    try {
      await agentCall(ref, widget.hostId, 'PUT', '/v1/media/volume', {'percent': ?percent, 'muted': ?muted});
    } catch (e) {
      if (mounted) toast(context, agentErrorText(l, e));
    }
    ref.invalidate(mediaProvider((widget.hostId, _player)));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(profileProvider).host(widget.hostId);
    final key = (widget.hostId, _player);
    final value = ref.watch(mediaProvider(key));
    return SettingsPage(
      title: host == null ? l.mediaTitle : '${l.mediaTitle} · ${host.name}',
      actions: [IconButton(tooltip: l.commonRefresh, icon: const Icon(LucideIcons.refreshCw), onPressed: () => ref.invalidate(mediaProvider(key)))],
      children: value.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
        error: (e, _) => [
          TCard(
            child: Row(children: [
              Icon(LucideIcons.circleAlert, color: t.danger),
              const SizedBox(width: 10),
              Expanded(child: Text(agentErrorText(l, e))),
              TextButton(onPressed: () => ref.invalidate(mediaProvider(key)), child: Text(l.commonRetry)),
            ]),
          ),
        ],
        data: (s) {
          final p = s.player;
          return [
            if (s.players.length > 1) ...[
              SizedBox(
                height: 40,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final (name, status) in s.players)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        selected: name == p?.name,
                        showCheckmark: false,
                        avatar: StatusDot(color: status == 'Playing' ? t.success : (status == 'Paused' ? t.warning : t.textSecondary), size: 8),
                        label: Text(playerLabel(name)),
                        tooltip: name,
                        onSelected: (_) => setState(() => _player = name),
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 12),
            ],
            if (p == null)
              TCard(
                child: Row(children: [
                  Icon(LucideIcons.music, color: t.textSecondary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.mediaNothingPlaying, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(l.mediaNothingHint, style: TextStyle(color: t.textSecondary, fontSize: 13)),
                    ]),
                  ),
                ]),
              )
            else
              _NowPlaying(hostId: widget.hostId, state: s, seekDrag: _seekDrag, onSeekDrag: (v) => setState(() => _seekDrag = v), onSeekEnd: (v) async {
                await _act('position', seconds: v);
                if (mounted) setState(() => _seekDrag = null);
              }, onAction: _act),
            // Velour (YouTube Music) has its own full remote: search, queue, lyrics, library.
            if (p != null && playerLabel(p.name) == 'Velour') ...[
              const SizedBox(height: 12),
              GroupedSection(children: [
                GroupedRow(
                  title: l.velourOpen,
                  subtitle: l.velourOpenHint,
                  icon: LucideIcons.listMusic,
                  iconBackground: const Color(0xFFFF375F),
                  onTap: () => context.push('/system/velour?host=${Uri.encodeQueryComponent(widget.hostId)}'),
                ),
              ]),
            ],
            if (s.volume case (final percent, final muted)) ...[
              const SizedBox(height: 12),
              TCard(
                padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
                child: Row(children: [
                  IconButton(
                    tooltip: muted ? l.mediaUnmute : l.mediaMute,
                    icon: Icon(muted ? LucideIcons.volumeX : (percent < 40 ? LucideIcons.volume1 : LucideIcons.volume2), color: muted ? t.danger : t.text),
                    onPressed: () => _volume(muted: !muted),
                  ),
                  Expanded(
                    child: Slider(
                      value: (_volDrag ?? percent.toDouble()).clamp(0, 100),
                      max: 100,
                      divisions: 20,
                      label: '%${(_volDrag ?? percent).round()}',
                      semanticFormatterCallback: (v) => '${l.mediaVolume} %${v.round()}',
                      onChanged: (v) => setState(() => _volDrag = v),
                      onChangeEnd: (v) async {
                        await _volume(percent: v.round());
                        if (mounted) setState(() => _volDrag = null);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(muted ? l.mediaMuted : '%${(_volDrag ?? percent).round()}',
                        textAlign: TextAlign.end, style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                ]),
              ),
            ],
          ];
        },
      ),
    );
  }
}

class _NowPlaying extends ConsumerWidget {
  const _NowPlaying({required this.hostId, required this.state, required this.seekDrag, required this.onSeekDrag, required this.onSeekEnd, required this.onAction});
  final String hostId;
  final MediaState state;
  final double? seekDrag;
  final ValueChanged<double> onSeekDrag;
  final ValueChanged<double> onSeekEnd;
  final Future<void> Function(String action, {double? seconds}) onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final p = state.player!;
    final pos = seekDrag ?? state.positionAt(ref.read(clockProvider)());
    final len = p.length;
    final sub = [p.artist, p.album].whereType<String>().join(' · ');
    return TCard(
      radius: TiphysTokens.radiusHero,
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
      child: Column(children: [
        LayoutBuilder(
          builder: (c, box) => MediaArt(hostId: hostId, player: p, size: box.maxWidth.clamp(120, 260).toDouble(), radius: 20),
        ),
        const SizedBox(height: 16),
        Text(p.title ?? l.mediaUnknownTitle, style: tt.titleLarge, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(sub, style: tt.bodyMedium?.copyWith(color: t.textSecondary), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: 4),
        Text(playerLabel(p.name), style: tt.labelSmall?.copyWith(color: t.textSecondary)),
        if (len != null && len > 0 && pos != null) ...[
          const SizedBox(height: 8),
          Slider(
            value: pos.clamp(0, len).toDouble(),
            max: len,
            semanticFormatterCallback: (v) => l.mediaPositionOf(mediaTime(v), mediaTime(len)),
            onChanged: onSeekDrag,
            onChangeEnd: onSeekEnd,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Row(children: [
              Text(mediaTime(pos), style: tt.labelSmall?.copyWith(color: t.textSecondary)),
              const Spacer(),
              Text(mediaTime(len), style: tt.labelSmall?.copyWith(color: t.textSecondary)),
            ]),
          ),
        ],
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(tooltip: l.mediaPrevious, iconSize: 26, icon: const Icon(LucideIcons.skipBack), onPressed: () => onAction('previous')),
          _SeekButton(back: true, onPressed: () => onAction('seek', seconds: -10)),
          Semantics(
            button: true,
            label: p.playing ? l.mediaPause : l.mediaPlay,
            child: Material(
              color: t.isDark ? t.tabActive : const Color(0xFF111114),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => onAction('play-pause'),
                child: SizedBox(
                  width: 64,
                  height: 64,
                  child: Icon(p.playing ? LucideIcons.pause : LucideIcons.play, size: 28, color: t.isDark ? Colors.black : Colors.white),
                ),
              ),
            ),
          ),
          _SeekButton(back: false, onPressed: () => onAction('seek', seconds: 10)),
          IconButton(tooltip: l.mediaNext, iconSize: 26, icon: const Icon(LucideIcons.skipForward), onPressed: () => onAction('next')),
        ]),
      ]),
    );
  }
}

class _SeekButton extends StatelessWidget {
  const _SeekButton({required this.back, required this.onPressed});
  final bool back;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return IconButton(
      tooltip: back ? l.mediaBack10 : l.mediaForward10,
      onPressed: onPressed,
      icon: Stack(alignment: Alignment.center, children: [
        Icon(back ? LucideIcons.rotateCcw : LucideIcons.rotateCw, size: 30),
        const Padding(padding: EdgeInsets.only(top: 2), child: Text('10', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800))),
      ]),
    );
  }
}

/// Cover: http(s) URL directly, local file via the agent; otherwise (or on load failure) a background with a note icon.
class MediaArt extends ConsumerWidget {
  const MediaArt({super.key, required this.hostId, required this.player, required this.size, this.radius = 12});
  final String hostId;
  final MediaPlayer player;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [t.accent, t.accent.withValues(alpha: 0.55)]),
      ),
      child: Icon(LucideIcons.music, size: size * 0.38, color: Colors.white.withValues(alpha: 0.9)),
    );
    Widget? image;
    if (player.artUrl != null) {
      image = Image.network(player.artUrl!, width: size, height: size, fit: BoxFit.cover, semanticLabel: l.mediaArt, errorBuilder: (_, _, _) => placeholder);
    } else if (player.localArt && player.artId != null) {
      final bytes = ref.watch(mediaArtProvider((hostId, player.name, player.artId!))).value;
      if (bytes != null) image = Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, semanticLabel: l.mediaArt, errorBuilder: (_, _, _) => placeholder);
    }
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: image ?? ExcludeSemantics(child: placeholder));
  }
}

/// Home screen "Now playing": doesn't show at all if nothing is playing/paused on the PC.
class NowPlayingCard extends ConsumerWidget {
  const NowPlayingCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(claudeHostProvider);
    if (host == null) return const SizedBox.shrink();
    final p = ref.watch(mediaProvider((host.id, null))).value?.player;
    if (p == null || p.status == 'Stopped') return const SizedBox.shrink();
    return TCard(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      onTap: () => context.push('/system/media?host=${Uri.encodeQueryComponent(host.id)}'),
      semanticLabel: l.homeCardsNowPlaying,
      child: Row(children: [
        MediaArt(hostId: host.id, player: p, size: 48, radius: 12),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${l.homeCardsNowPlaying} · ${playerLabel(p.name)}',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: p.playing ? t.success : t.textSecondary), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(p.title ?? l.mediaUnknownTitle, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (p.artist != null) Text(p.artist!, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        IconButton(
          tooltip: p.playing ? l.mediaPause : l.mediaPlay,
          icon: Icon(p.playing ? LucideIcons.pause : LucideIcons.play),
          onPressed: () => mediaAction(ref, context, host.id, 'play-pause', player: p.name),
        ),
        IconButton(tooltip: l.mediaNext, icon: const Icon(LucideIcons.skipForward), onPressed: () => mediaAction(ref, context, host.id, 'next', player: p.name)),
      ]),
    );
  }
}

