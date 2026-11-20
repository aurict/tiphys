// System › Media › Velour: the Velour YouTube Music player on the PC, as a music app on the phone.
// - Shell: Home · Explore · Search · Library at the bottom, a mini player above them (tap or swipe up = full player,
//   swipe sideways = next/previous) and the PC panel in the app bar.
// - Full player (velour_player.dart): cover-coloured backdrop, swipe/double-tap cover, controls, and a panel with
//   Up next · Lyrics · PC. The PC panel (velour_pc.dart): Velour and system volume, audio output, equalizer, sleep timer,
//   screen off, show Velour on the PC, phone controls.
// - State is live (velour_data.dart); command answers carry the new state, taps change the screen at once (optimistic).
// - On Android the phone's lock screen/notification and, while this screen is open, its volume buttons control Velour
//   (velour_media.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../desktop/desktop_data.dart';
import 'agent_providers.dart';
import 'media.dart' show mediaTime;
import 'velour_color.dart';
import 'velour_data.dart';
import 'velour_media.dart';

part 'velour_player.dart';
part 'velour_pc.dart';

/// Sends a command and applies the state it answers with. [optimistic] changes the screen before the answer (the
/// next pushed state replaces it; on an error the state is fetched again). Shows `done` or the error.
Future<bool> velourAct(
  WidgetRef ref,
  BuildContext context,
  String hostId,
  Map<String, Object?> op, {
  String? done,
  VState Function(VState s, DateTime now)? optimistic,
}) async {
  final l = AppLocalizations.of(context);
  // `ref` may belong to a sheet that closes meanwhile: the notifier comes from the screen's container.
  final live = ProviderScope.containerOf(context, listen: false).read(velourStateProvider(hostId).notifier);
  if (optimistic != null) live.patch(optimistic);
  unawaited(HapticFeedback.selectionClick());
  try {
    live.apply(await velourCall(ref, hostId, op));
    if (done != null && context.mounted) toast(context, done);
    return true;
  } catch (e) {
    if (optimistic != null) live.retry();
    if (context.mounted) toast(context, velourErrorText(l, e));
    return false;
  }
}

/// Hero tag of the cover (mini player ↔ full player).
String velourArtHero(String hostId) => 'velour-art-$hostId';

class VelourScreen extends ConsumerStatefulWidget {
  const VelourScreen({super.key, required this.hostId, this.openPlayer = false});
  final String hostId;

  /// Opens the full player once something is playing (coming from "Open Velour remote").
  final bool openPlayer;
  @override
  ConsumerState<VelourScreen> createState() => _VelourScreenState();
}

class _VelourScreenState extends ConsumerState<VelourScreen> {
  int _tab = 0;

  /// Tabs built so far (the others don't load until they are first opened).
  final _visited = <int>{0};
  bool _playerOpened = false;
  late final VelourMedia _media = ref.read(velourMediaProvider.notifier);
  StreamSubscription<int>? _volumeKeys;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _media.screenOpened(widget.hostId, AppLocalizations.of(context));
    });
    _volumeKeys = _media.volumeKeys.listen((v) {
      if (mounted) toast(context, AppLocalizations.of(context).velourVolumeToast(v));
    });
  }

  @override
  void dispose() {
    unawaited(_volumeKeys?.cancel());
    _media.screenClosed(widget.hostId);
    super.dispose();
  }

  void _select(int i) => setState(() {
        _tab = i;
        _visited.add(i);
      });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(profileProvider).host(widget.hostId);
    if (widget.openPlayer && !_playerOpened && ref.watch(velourStateProvider(widget.hostId)).value?.track != null) {
      _playerOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openVelourPlayer(context, widget.hostId);
      });
    }
    final tabs = [
      (LucideIcons.house, l.velourTabHome),
      (LucideIcons.compass, l.velourTabExplore),
      (LucideIcons.search, l.velourTabSearch),
      (LucideIcons.libraryBig, l.velourTabLibrary),
    ];
    Widget body(int i) => !_visited.contains(i)
        ? const SizedBox.shrink()
        : switch (i) {
            0 => _HomeTab(hostId: widget.hostId, onSearch: () => _select(2)),
            1 => VelourPageBody(hostId: widget.hostId, source: const VSource.explore()),
            2 => _SearchTab(hostId: widget.hostId),
            _ => _LibraryTab(hostId: widget.hostId),
          };
    return Scaffold(
      // Opaque: the mini player's translucent dark-theme card needs the theme ground behind it.
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.isDark ? const Color(0xCC000000) : t.background,
        title: Text(host == null ? l.velourTitle : '${l.velourTitle} · ${host.name}'),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(LucideIcons.chevronLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          IconButton(
            tooltip: l.velourPcTitle,
            icon: const Icon(LucideIcons.monitorSpeaker),
            onPressed: () => showVelourPanel(context, widget.hostId, VelourPanelTab.pc),
          ),
        ],
      ),
      body: AmbientBackground(child: IndexedStack(index: _tab, children: [for (var i = 0; i < tabs.length; i++) body(i)])),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        VelourMiniPlayer(hostId: widget.hostId, onTap: () => openVelourPlayer(context, widget.hostId)),
        NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _select,
          height: 66,
          backgroundColor: t.isDark ? const Color(0xF20B0B0F) : t.card,
          indicatorColor: t.accent.withValues(alpha: t.isDark ? 0.35 : 0.14),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final (icon, label) in tabs) NavigationDestination(icon: Icon(icon), label: label),
          ],
        ),
      ]),
    );
  }
}

// =====================================================================
// home

class _HomeTab extends ConsumerWidget {
  const _HomeTab({required this.hostId, required this.onSearch});
  final String hostId;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final hour = ref.watch(clockProvider)().hour;
    final greeting = switch (hour) {
      >= 5 && < 12 => l.velourGreetingMorning,
      >= 12 && < 18 => l.velourGreetingDay,
      >= 18 && < 23 => l.velourGreetingEvening,
      _ => l.velourGreetingNight,
    };
    final state = ref.watch(velourStateProvider(hostId));
    final quick = [
      (const VSource('liked'), l.velourLibLiked, LucideIcons.heart, const Color(0xFFFF375F)),
      (const VSource('history'), l.velourLibHistory, LucideIcons.history, const Color(0xFF0A84FF)),
    ];
    final title = Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Text(greeting, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
    );
    // Velour unreachable: one card (the page would only fail the same way); the live state brings the page back.
    if (state.hasError && !state.hasValue) {
      return ListView(padding: _pad, children: [
        title,
        VelourErrorCard(error: state.error!, onRetry: () => ref.read(velourStateProvider(hostId).notifier).retry()),
      ]);
    }
    return VelourPageBody(hostId: hostId, source: const VSource.home(), leading: [
      title,
      if (state.value?.track == null && state.hasValue)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: VelourEmpty(
            icon: LucideIcons.music,
            text: l.velourNothingPlaying,
            hint: l.velourNothingHint,
            action: TextButton(onPressed: onSearch, child: Text(l.velourTabSearch)),
          ),
        ),
      Row(children: [
        for (final (i, (src, label, icon, color)) in quick.indexed) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: TCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              radius: 16,
              onTap: () => openVelourPage(context, hostId, src, label),
              semanticLabel: label,
              child: Row(children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, size: 18, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: t.text))),
              ]),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 4),
    ]);
  }
}

// =====================================================================
// mini player

class VelourMiniPlayer extends ConsumerStatefulWidget {
  const VelourMiniPlayer({super.key, required this.hostId, required this.onTap});
  final String hostId;
  final VoidCallback onTap;
  @override
  ConsumerState<VelourMiniPlayer> createState() => _VelourMiniPlayerState();
}

class _VelourMiniPlayerState extends ConsumerState<VelourMiniPlayer> {
  Timer? _tick;
  String? _precached;
  double _dx = 0;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(velourStateProvider(widget.hostId)).value?.playing == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = ref.watch(velourStateProvider(widget.hostId)).value;
    final track = s?.track;
    if (s == null || track == null) return const SizedBox.shrink();
    final len = s.length;
    final pos = s.positionAt(ref.read(clockProvider)());
    final cover = track.thumbnail;
    final tone = cover == null ? null : ref.watch(velourCoverColorProvider(cover)).value;
    // The full player's cover, decoded ahead: the open animation then flies a ready image instead of an empty one.
    if (cover != null && cover != _precached) {
      _precached = cover;
      unawaited(precacheImage(NetworkImage(cover), context, onError: (_, _) {}));
    }
    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: GestureDetector(
          // Sideways: next/previous song; up: the full player.
          onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (_dx < -60 || v < -500) velourAct(ref, context, widget.hostId, {'op': 'next'});
            if (_dx > 60 || v > 500) velourAct(ref, context, widget.hostId, {'op': 'prev'});
            setState(() => _dx = 0);
          },
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -300) widget.onTap();
          },
          child: Transform.translate(
            offset: Offset(_dx.clamp(-80, 80).toDouble(), 0),
            child: TCard(
              padding: EdgeInsets.zero,
              radius: 18,
              color: tone == null ? null : Color.alphaBlend(playerTone(tone).withValues(alpha: t.isDark ? 0.55 : 0.12), t.card),
              onTap: widget.onTap,
              semanticLabel: '${l.velourOpenPlayer}: ${track.title}, ${track.artistLine}',
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
                  child: Row(children: [
                    Hero(tag: velourArtHero(widget.hostId), child: VelourArt(url: cover, size: 44, radius: 10)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(track.title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5, color: t.text), maxLines: 1, overflow: TextOverflow.ellipsis),
                        Text(track.artistLine, style: TextStyle(color: t.textSecondary, fontSize: 12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                      ]),
                    ),
                    IconButton(
                      tooltip: track.liked ? l.velourUnlike : l.velourLike,
                      icon: Icon(LucideIcons.heart, color: track.liked ? const Color(0xFFFF375F) : t.textSecondary, fill: track.liked ? 1 : 0),
                      onPressed: () => _like(track),
                    ),
                    IconButton(
                      tooltip: s.playing ? l.mediaPause : l.mediaPlay,
                      icon: Icon(s.playing ? LucideIcons.pause : LucideIcons.play, color: t.text),
                      onPressed: () => velourAct(ref, context, widget.hostId, {'op': 'toggle'}, optimistic: (s, now) => s.copyWith(now, playing: !s.playing)),
                    ),
                  ]),
                ),
                if (len > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: (pos / len).clamp(0, 1).toDouble(),
                        minHeight: 2.5,
                        color: t.text,
                        backgroundColor: t.text.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  void _like(VTrack track) {
    final like = track.liked ? 'indifferent' : 'like';
    velourAct(ref, context, widget.hostId, {'op': 'rate', 'videoId': track.videoId, 'like': like}, optimistic: (s, now) => s.copyWith(now, like: like));
  }
}

// =====================================================================
// shared pieces

const _pad = EdgeInsets.fromLTRB(TiphysTokens.gutter, 12, TiphysTokens.gutter, 32);

/// Pixel width to decode a cover shown [size] wide, rounded up to a few steps (fewer cache entries); null = full size.
int? decodeWidth(BuildContext context, double size) {
  final px = size * MediaQuery.devicePixelRatioOf(context);
  for (final step in const [96, 192, 384]) {
    if (px <= step) return step;
  }
  return null;
}

/// Cover from YouTube Music (http URL); a note icon on failure or without one.
class VelourArt extends StatelessWidget {
  const VelourArt({super.key, required this.url, required this.size, this.radius = 10, this.round = false});
  final String? url;
  final double size;
  final double radius;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final r = BorderRadius.circular(round ? size / 2 : radius);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: r,
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [t.accent, t.accent.withValues(alpha: 0.55)]),
      ),
      child: Icon(LucideIcons.music, size: size * 0.4, color: Colors.white.withValues(alpha: 0.9)),
    );
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: r,
        child: url == null
            ? placeholder
            : Image.network(
                url!,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // Decoded at the size it is shown (a 544 px cover for a 46 px row wastes memory and time); the big
                // player cover keeps the full image.
                cacheWidth: decodeWidth(context, size),
                errorBuilder: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// Error card; "Velour unreachable" explains how to turn the socket on.
class VelourErrorCard extends StatelessWidget {
  const VelourErrorCard({super.key, required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return TCard(
      child: Row(children: [
        Icon(LucideIcons.circleAlert, color: t.danger),
        const SizedBox(width: 12),
        Expanded(child: Text(velourErrorText(l, error))),
        TextButton(onPressed: onRetry, child: Text(l.commonRetry)),
      ]),
    );
  }
}

class VelourEmpty extends StatelessWidget {
  const VelourEmpty({super.key, required this.icon, required this.text, this.hint, this.action});
  final IconData icon;
  final String text;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TCard(
      child: Row(children: [
        Icon(icon, color: t.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: Theme.of(context).textTheme.titleMedium),
            if (hint != null) ...[
              const SizedBox(height: 2),
              Text(hint!, style: TextStyle(color: t.textSecondary, fontSize: 13)),
            ],
          ]),
        ),
        ?action,
      ]),
    );
  }
}

const _loading = VelourSkeleton();

/// Placeholder rows while a list loads (gently pulsing; still with reduced motion).
class VelourSkeleton extends StatefulWidget {
  const VelourSkeleton({super.key, this.rows = 6});
  final int rows;
  @override
  State<VelourSkeleton> createState() => _VelourSkeletonState();
}

class _VelourSkeletonState extends State<VelourSkeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final base = context.tokens.text.withValues(alpha: 0.08);
    Widget box(double w, double h, [double r = 6]) => Container(width: w, height: h, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(r)));
    return Semantics(
      label: l.commonLoading,
      child: ExcludeSemantics(
        child: FadeTransition(
          opacity: Tween(begin: 0.45, end: 1.0).animate(_c),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              for (var i = 0; i < widget.rows; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                  child: Row(children: [
                    box(46, 46, 8),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        FractionallySizedBox(widthFactor: 0.4 + (i * 37 % 40) / 100, child: box(double.infinity, 13)),
                        const SizedBox(height: 7),
                        FractionallySizedBox(widthFactor: 0.3 + (i * 23 % 30) / 100, child: box(double.infinity, 11)),
                      ]),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One song row: cover, title, artists · length; tap plays, the ⋮ button opens the song menu.
class VelourTrackTile extends StatelessWidget {
  const VelourTrackTile({super.key, required this.hostId, required this.track, this.onTap, this.current = false, this.index, this.trailing, this.playlistId, this.onRemoved});
  final String hostId;

  /// The playlist this row is shown in (offers "Remove from this playlist" for your own lists).
  final String? playlistId;
  final VoidCallback? onRemoved;
  final VTrack track;
  final VoidCallback? onTap;
  final bool current;
  final int? index;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final sub = [track.artistLine, if (track.duration != null) mediaTime(track.duration!.toDouble())].where((s) => s.isNotEmpty).join(' · ');
    final enabled = track.playable;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : () => toast(context, l.velourTrackUnavailable),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 0, 6),
            child: Row(children: [
              VelourArt(url: track.thumbnail, size: 46, radius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    if (current) ...[
                      Icon(LucideIcons.audioLines, size: 15, color: t.accent, semanticLabel: l.velourTabNowPlaying),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(track.title,
                          style: tt.titleMedium?.copyWith(color: current ? t.accent : t.text, fontWeight: current ? FontWeight.w700 : null),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ]),
                  if (sub.isNotEmpty) Text(sub, style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              trailing ??
                  IconButton(
                    tooltip: l.velourMore,
                    icon: Icon(LucideIcons.ellipsisVertical, color: t.textSecondary),
                    onPressed: () => showVelourTrackMenu(context, hostId, track, playlistId: playlistId, onRemoved: onRemoved),
                  ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Song menu: play next, add to queue, radio, add to playlist, like/dislike, remove from the playlist, go to artist/album.
Future<void> showVelourTrackMenu(BuildContext context, String hostId, VTrack track, {String? playlistId, VoidCallback? onRemoved}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheet) => Consumer(builder: (sheet, ref, _) {
      final l = AppLocalizations.of(sheet);
      final nav = Navigator.of(sheet);
      final artist = track.artists.where((a) => a.browseId != null).firstOrNull;
      Future<void> run(Map<String, Object?> op, String done) async {
        nav.pop();
        await velourAct(ref, context, hostId, op, done: done);
      }

      return ListView(shrinkWrap: true, children: [
        ListTile(
          leading: VelourArt(url: track.thumbnail, size: 44, radius: 8),
          title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(track.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const Divider(),
        if (track.playable) ...[
          ListTile(
            leading: const Icon(LucideIcons.listStart),
            title: Text(l.velourPlayNext),
            onTap: () => run({'op': 'play-next', 'track': track.json}, l.velourAddedNext(track.title)),
          ),
          ListTile(
            leading: const Icon(LucideIcons.listPlus),
            title: Text(l.velourAddToQueue),
            onTap: () => run({'op': 'add-to-queue', 'track': track.json}, l.velourAddedQueue(track.title)),
          ),
          ListTile(
            leading: const Icon(LucideIcons.radio),
            title: Text(l.velourRadio),
            onTap: () => run({'op': 'radio', 'videoId': track.videoId}, l.velourRadioStarted),
          ),
        ],
        ListTile(
          leading: const Icon(LucideIcons.listMusic),
          title: Text(l.velourAddToPlaylist),
          onTap: () {
            nav.pop();
            showVelourPlaylistPicker(context, hostId, [track.videoId]);
          },
        ),
        ListTile(
          leading: Icon(track.liked ? LucideIcons.heartOff : LucideIcons.heart),
          title: Text(track.liked ? l.velourUnlike : l.velourLike),
          onTap: () => run({'op': 'rate', 'videoId': track.videoId, 'like': track.liked ? 'indifferent' : 'like'}, track.liked ? l.velourUnliked : l.velourLiked),
        ),
        if (track.like != 'dislike')
          ListTile(
            leading: const Icon(LucideIcons.thumbsDown),
            title: Text(l.velourDislike),
            onTap: () => run({'op': 'rate', 'videoId': track.videoId, 'like': 'dislike'}, l.velourDisliked),
          ),
        // Only rows of your own playlists carry a setVideoId.
        if (playlistId != null && track.json['setVideoId'] is String)
          ListTile(
            leading: const Icon(LucideIcons.listMinus),
            title: Text(l.velourRemoveFromPlaylist),
            onTap: () async {
              nav.pop();
              final ok = await velourAct(ref, context, hostId,
                  {'op': 'remove-from-playlist', 'playlistId': playlistId, 'videoId': track.videoId, 'setVideoId': track.json['setVideoId']},
                  done: l.velourRemovedFromPlaylist);
              if (ok) onRemoved?.call();
            },
          ),
        if (artist != null)
          ListTile(
            leading: const Icon(LucideIcons.micVocal),
            title: Text(l.velourGoArtist),
            subtitle: Text(artist.name),
            onTap: () {
              nav.pop();
              openVelourPage(context, hostId, VSource.page(artist.browseId!), artist.name);
            },
          ),
        if (track.album?.browseId != null)
          ListTile(
            leading: const Icon(LucideIcons.discAlbum),
            title: Text(l.velourGoAlbum),
            subtitle: Text(track.album!.name),
            onTap: () {
              nav.pop();
              openVelourPage(context, hostId, VSource.page(track.album!.browseId!), track.album!.name);
            },
          ),
        const SizedBox(height: 8),
      ]);
    }),
  );
}

/// "Add to playlist": your playlists, or a new one.
Future<void> showVelourPlaylistPicker(BuildContext context, String hostId, List<String> videoIds) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (sheet) => Consumer(builder: (sheet, ref, _) {
      final l = AppLocalizations.of(sheet);
      final nav = Navigator.of(sheet);
      final lists = ref.watch(velourPlaylistsProvider(hostId));
      return ListView(shrinkWrap: true, children: [
        ListTile(title: Text(l.velourAddToPlaylist, style: Theme.of(sheet).textTheme.titleMedium)),
        ListTile(
          leading: const Icon(LucideIcons.plus),
          title: Text(l.velourNewPlaylist),
          onTap: () async {
            nav.pop();
            final title = await _askName(context, l.velourNewPlaylist);
            if (title == null || !context.mounted) return;
            final container = ProviderScope.containerOf(context, listen: false);
            await velourAct(ref, context, hostId, {'op': 'create-playlist', 'title': title, 'videoIds': videoIds}, done: l.velourCreatedPlaylist(title));
            container.invalidate(velourPlaylistsProvider(hostId));
          },
        ),
        ...lists.when(
          loading: () => [_loading],
          error: (e, _) => [ListTile(title: Text(velourErrorText(l, e)))],
          data: (ps) => ps.isEmpty
              ? [ListTile(title: Text(l.velourNoPlaylists, style: TextStyle(color: sheet.tokens.textSecondary)))]
              : [
                  for (final (id, name) in ps)
                    ListTile(
                      leading: const Icon(LucideIcons.listMusic),
                      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () async {
                        nav.pop();
                        await velourAct(ref, context, hostId, {'op': 'add-to-playlist', 'playlistId': id, 'videoIds': videoIds},
                            done: l.velourAddedToPlaylist(name));
                      },
                    ),
                ],
        ),
        const SizedBox(height: 8),
      ]);
    }),
  );
}

Future<String?> _askName(BuildContext context, String title) =>
    showDialog<String>(context: context, builder: (_) => _NameDialog(title: title));

/// Owns its text controller, so it lives until the dialog's closing animation is over.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title});
  final String title;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final v = _c.text.trim();
    if (v.isNotEmpty) Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 150,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(labelText: l.velourPlaylistName),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
        FilledButton(onPressed: _submit, child: Text(l.commonCreate)),
      ],
    );
  }
}

/// Route name of pages opened from the Velour screen (the mini player pops back through them).
const _pageRoute = 'velour-page';

void openVelourPage(BuildContext context, String hostId, VSource source, String title) {
  // From the full player: back to the browsing screens first.
  Navigator.of(context).popUntil((r) => r.settings.name != velourPlayerRoute);
  Navigator.of(context).push(MaterialPageRoute<void>(
    settings: const RouteSettings(name: _pageRoute),
    builder: (_) => VelourPageScreen(hostId: hostId, source: source, title: title),
  ));
}

// =====================================================================
// pages (search results, library, album/playlist/artist)

/// Renders a page and loads its continuation on demand.
class VelourPageBody extends ConsumerStatefulWidget {
  const VelourPageBody({super.key, required this.hostId, required this.source, this.leading = const [], this.showHeader = false});
  final String hostId;
  final VSource source;

  /// Widgets above the sections (search box, library chips).
  final List<Widget> leading;
  final bool showHeader;
  @override
  ConsumerState<VelourPageBody> createState() => _VelourPageBodyState();
}

class _VelourPageBodyState extends ConsumerState<VelourPageBody> {
  VPage? _more;
  bool _loadingMore = false;

  @override
  void didUpdateWidget(VelourPageBody old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) _more = null;
  }

  Future<void> _loadMore(VPage page) async {
    final token = page.continuation;
    if (token == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final r = VPage(await velourCall(ref, widget.hostId, {'op': 'more', 'token': token}) as Map);
      if (mounted) setState(() => _more = page.append(r));
    } catch (e) {
      if (mounted) toast(context, velourErrorText(AppLocalizations.of(context), e));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final key = (widget.hostId, widget.source);
    final value = ref.watch(velourPageProvider(key));
    return RefreshIndicator(
      onRefresh: () async {
        _more = null;
        ref.invalidate(velourPageProvider(key));
        await ref.read(velourPageProvider(key).future).catchError((_) => VPage.of(null, const [], null));
      },
      child: ListView(padding: _pad, physics: const AlwaysScrollableScrollPhysics(), children: [
        ...widget.leading,
        ...value.when(
          skipLoadingOnRefresh: true,
          loading: () => [_loading],
          error: (e, _) => [VelourErrorCard(error: e, onRetry: () => ref.invalidate(velourPageProvider(key)))],
          data: (fetched) {
            final page = _more ?? fetched;
            return [
              if (widget.showHeader && page.header != null) _PageHeader(hostId: widget.hostId, page: page),
              if (page.isEmpty) VelourEmpty(icon: LucideIcons.searchX, text: widget.source.op == 'search' ? l.commonNothingFound : l.commonEmpty),
              for (final s in page.sections)
                if (s.items.isNotEmpty)
                  _Section(
                    hostId: widget.hostId,
                    section: s,
                    playlistId: widget.showHeader ? page.header?.playlistId : null,
                    onRemoved: () {
                      _more = null;
                      ref.invalidate(velourPageProvider(key));
                    },
                  ),
              if (page.continuation != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Center(
                    child: _loadingMore
                        ? const CircularProgressIndicator()
                        : OutlinedButton.icon(icon: const Icon(LucideIcons.chevronsDown), label: Text(l.velourLoadMore), onPressed: () => _loadMore(page)),
                  ),
                ),
            ];
          },
        ),
      ]),
    );
  }
}

class _Section extends ConsumerWidget {
  const _Section({required this.hostId, required this.section, this.playlistId, this.onRemoved});
  final String hostId;
  final VSection section;
  final String? playlistId;
  final VoidCallback? onRemoved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = section;
    final title = s.title.isEmpty ? null : SectionLabel(s.title);
    if (s.layout == 'list') {
      final tracks = s.tracks;
      final rows = <Widget>[];
      for (final item in s.items) {
        if (rows.isNotEmpty) rows.add(Divider(height: 1, indent: 70, color: context.tokens.separator));
        final tr = item.track;
        if (tr != null) {
          final at = tracks.indexOf(tr);
          rows.add(VelourTrackTile(
            hostId: hostId,
            track: tr,
            playlistId: playlistId,
            onRemoved: onRemoved,
            onTap: () => velourAct(ref, context, hostId, {'op': 'play', 'tracks': [for (final x in tracks) x.json], 'start': at}),
          ));
        } else {
          rows.add(_CardRow(hostId: hostId, card: item.card!));
        }
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ?title,
        if (title == null) const SizedBox(height: 12),
        TCard(padding: EdgeInsets.zero, radius: TiphysTokens.radiusList, child: Column(children: rows)),
      ]);
    }
    final cards = [for (final i in s.items) ?i.card];
    if (s.layout == 'carousel') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ?title,
        if (title == null) const SizedBox(height: 12),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _CardTile(hostId: hostId, card: cards[i]),
          ),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ?title,
      if (title == null) const SizedBox(height: 12),
      TCard(
        padding: EdgeInsets.zero,
        radius: TiphysTokens.radiusList,
        child: Column(children: [
          for (var i = 0; i < cards.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 70, color: context.tokens.separator),
            _CardRow(hostId: hostId, card: cards[i]),
          ],
        ]),
      ),
    ]);
  }
}

void _openCard(BuildContext context, WidgetRef ref, String hostId, VCard card) {
  final tg = card.target;
  if (tg.isWatch) {
    velourAct(ref, context, hostId, {'op': 'play-target', 'target': tg.json});
  } else if (tg.id != null) {
    openVelourPage(context, hostId, VSource.page(tg.id!, tg.params), card.title);
  }
}

/// Album/playlist/artist as a row (grids, lists).
class _CardRow extends ConsumerWidget {
  const _CardRow({required this.hostId, required this.card});
  final String hostId;
  final VCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => _openCard(context, ref, hostId, card),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
          child: Row(children: [
            VelourArt(url: card.thumbnail, size: 46, radius: 8, round: card.round),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(card.title, style: tt.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (card.subtitle.isNotEmpty) Text(card.subtitle, style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            Icon(card.target.isWatch ? LucideIcons.play : Icons.chevron_right_rounded, size: 20, color: context.tokens.textSecondary),
          ]),
        ),
      ),
    );
  }
}

/// Album/playlist/artist as a tile (carousels).
class _CardTile extends ConsumerWidget {
  const _CardTile({required this.hostId, required this.card});
  final String hostId;
  final VCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tt = Theme.of(context).textTheme;
    return SizedBox(
      width: 136,
      child: Semantics(
        button: true,
        label: [card.title, card.subtitle].where((s) => s.isNotEmpty).join(', '),
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _openCard(context, ref, hostId, card),
          child: Column(crossAxisAlignment: card.round ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
            VelourArt(url: card.thumbnail, size: 136, radius: 12, round: card.round),
            const SizedBox(height: 6),
            Text(card.title, style: tt.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: card.round ? TextAlign.center : TextAlign.start),
            if (card.subtitle.isNotEmpty)
              Text(card.subtitle, style: tt.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: card.round ? TextAlign.center : TextAlign.start),
          ]),
        ),
      ),
    );
  }
}

/// Album/playlist/artist header: cover, title, Play / Shuffle / Radio.
class _PageHeader extends ConsumerWidget {
  const _PageHeader({required this.hostId, required this.page});
  final String hostId;
  final VPage page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final h = page.header!;
    final tracks = [for (final s in page.sections) if (s.layout == 'list') ...s.tracks.where((x) => x.playable)];
    final play = h.play?.isWatch == true ? h.play : null;
    final radio = h.radio?.isWatch == true ? h.radio : null;
    Map<String, Object?> playAll({required bool shuffle}) =>
        {'op': 'play', 'tracks': [for (final x in tracks) x.json], 'start': 0, 'shuffle': shuffle};
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(children: [
        VelourArt(url: h.thumbnail, size: 180, radius: 16, round: h.round),
        const SizedBox(height: 14),
        Text(h.title, style: tt.titleLarge, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        for (final sub in [h.subtitle, h.secondSubtitle])
          if (sub.isNotEmpty) Text(sub, style: tt.bodySmall?.copyWith(color: t.textSecondary), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 12),
        Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 8, children: [
          if (play != null || tracks.isNotEmpty)
            FilledButton.icon(
              icon: const Icon(LucideIcons.play, size: 18),
              label: Text(l.velourPlay),
              onPressed: () => velourAct(ref, context, hostId, tracks.isNotEmpty ? playAll(shuffle: false) : {'op': 'play-target', 'target': play!.json}),
            ),
          if (tracks.length > 1)
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.shuffle, size: 18),
              label: Text(l.velourShufflePlay),
              onPressed: () => velourAct(ref, context, hostId, playAll(shuffle: true)),
            ),
          if (radio != null)
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.radio, size: 18),
              label: Text(l.velourRadio),
              onPressed: () => velourAct(ref, context, hostId, {'op': 'play-target', 'target': radio.json}),
            ),
          if (h.playlistId != null && !h.round)
            OutlinedButton.icon(
              icon: const Icon(LucideIcons.libraryBig, size: 18),
              label: Text(l.velourSaveToLibrary),
              onPressed: () => velourAct(ref, context, hostId, {'op': 'save-to-library', 'playlistId': h.playlistId, 'save': true}, done: l.velourSavedToLibrary),
            ),
        ]),
      ]),
    );
  }
}

class VelourPageScreen extends StatelessWidget {
  const VelourPageScreen({super.key, required this.hostId, required this.source, required this.title});
  final String hostId;
  final VSource source;
  final String title;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      // Opaque: the mini player's translucent dark-theme card needs the theme ground behind it.
      backgroundColor: t.background,
      appBar: AppBar(
        backgroundColor: t.isDark ? const Color(0xCC000000) : t.background,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(LucideIcons.chevronLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: AmbientBackground(child: VelourPageBody(hostId: hostId, source: source, showHeader: true)),
      bottomNavigationBar: SafeArea(top: false, child: VelourMiniPlayer(hostId: hostId, onTap: () => openVelourPlayer(context, hostId))),
    );
  }
}

// =====================================================================
// search

class _SearchTab extends ConsumerStatefulWidget {
  const _SearchTab({required this.hostId});
  final String hostId;
  @override
  ConsumerState<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends ConsumerState<_SearchTab> with AutomaticKeepAliveClientMixin {
  final _text = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _typed = '';
  String? _query;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    _text.text = q;
    _focus.unfocus();
    setState(() {
      _query = q;
      _typed = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final box = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: TextField(
        controller: _text,
        focusNode: _focus,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: l.velourSearchHint,
          prefixIcon: const Icon(LucideIcons.search),
          suffixIcon: _text.text.isEmpty
              ? null
              : IconButton(
                  tooltip: l.velourClearSearch,
                  icon: const Icon(LucideIcons.x),
                  onPressed: () => setState(() {
                    _text.clear();
                    _typed = '';
                    _focus.requestFocus();
                  }),
                ),
        ),
        onChanged: (v) {
          _debounce?.cancel();
          _debounce = Timer(const Duration(milliseconds: 300), () {
            if (mounted) setState(() => _typed = v.trim());
          });
        },
        onSubmitted: _submit,
      ),
    );
    final suggesting = _focus.hasFocus && _typed.length >= 2 && _typed != _query;
    if (suggesting) {
      final sug = ref.watch(velourSuggestProvider((widget.hostId, _typed))).value ?? const [];
      return ListView(padding: _pad, children: [
        box,
        if (sug.isNotEmpty)
          TCard(
            padding: EdgeInsets.zero,
            radius: TiphysTokens.radiusList,
            child: Column(children: [
              for (final s in sug.take(8))
                ListTile(
                  leading: Icon(LucideIcons.search, size: 18, color: t.textSecondary),
                  title: Text(s, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _submit(s),
                ),
            ]),
          ),
      ]);
    }
    if (_query == null) {
      return ListView(padding: _pad, children: [
        box,
        const SizedBox(height: 8),
        VelourEmpty(icon: LucideIcons.search, text: l.velourSearchStart, hint: l.velourSearchStartHint),
      ]);
    }
    return VelourPageBody(hostId: widget.hostId, source: VSource.search(_query!), leading: [box]);
  }
}

// =====================================================================
// library

class _LibraryTab extends ConsumerStatefulWidget {
  const _LibraryTab({required this.hostId});
  final String hostId;
  @override
  ConsumerState<_LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends ConsumerState<_LibraryTab> with AutomaticKeepAliveClientMixin {
  VSource _source = const VSource.library('playlists');

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final l = AppLocalizations.of(context);
    final choices = [
      (const VSource.library('playlists'), l.velourLibPlaylists, LucideIcons.listMusic),
      (const VSource.library('albums'), l.velourLibAlbums, LucideIcons.discAlbum),
      (const VSource.library('artists'), l.velourLibArtists, LucideIcons.micVocal),
      (const VSource('liked'), l.velourLibLiked, LucideIcons.heart),
      (const VSource('history'), l.velourLibHistory, LucideIcons.history),
    ];
    return VelourPageBody(
      hostId: widget.hostId,
      source: _source,
      showHeader: false,
      leading: [
        // One scrollable row, so the list starts high on a phone.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final (src, label, icon) in choices)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  avatar: Icon(icon, size: 16),
                  label: Text(label),
                  selected: _source == src,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _source = src),
                ),
              ),
          ]),
        ),
      ],
    );
  }
}
