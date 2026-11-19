// System › Media › Velour: full remote for the Velour YouTube Music player on the PC.
// Tabs: Now playing (controls, like, volume, lyrics), Up next (jump / swipe to remove / drag to reorder / clear),
// Search (suggestions, results) and Library (playlists, albums, artists, liked, history). Albums, playlists and artists
// open as their own page with Play / Shuffle / Radio. A mini player stays at the bottom outside "Now playing".
// State is polled every 2 s while visible; the position advances locally in between.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import 'media.dart' show mediaTime;
import 'velour_data.dart';

/// Sends a command, shows `done` (or the error), then refreshes the state — again shortly after, because the player
/// reports pause/position changes a moment later. `ref` may belong to a sheet that closes meanwhile, so the refresh
/// goes through the container of `context` (the screen).
Future<bool> velourAct(WidgetRef ref, BuildContext context, String hostId, Map<String, Object?> op, {String? done}) async {
  final l = AppLocalizations.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  var ok = true;
  try {
    await velourCall(ref, hostId, op);
    if (done != null && context.mounted) toast(context, done);
  } catch (e) {
    ok = false;
    if (context.mounted) toast(context, velourErrorText(l, e));
  }
  container.invalidate(velourStateProvider(hostId));
  unawaited(Future<void>.delayed(const Duration(milliseconds: 450), () => container.invalidate(velourStateProvider(hostId))));
  return ok;
}

class VelourScreen extends ConsumerStatefulWidget {
  const VelourScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<VelourScreen> createState() => _VelourScreenState();
}

class _VelourScreenState extends ConsumerState<VelourScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this)..addListener(() => setState(() {}));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final host = ref.watch(profileProvider).host(widget.hostId);
    return Scaffold(
      // Opaque: the mini player's translucent dark-theme card needs the theme ground behind it.
      backgroundColor: t.background,
      body: AmbientBackground(
        child: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverAppBar(
              pinned: true,
              backgroundColor: t.isDark ? const Color(0xCC000000) : t.background,
              title: Text(host == null ? l.velourTitle : '${l.velourTitle} · ${host.name}'),
              leading: IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(LucideIcons.chevronLeft),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              bottom: TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                tabs: [
                  Tab(text: l.velourTabNowPlaying),
                  Tab(text: l.velourTabQueue),
                  Tab(text: l.velourTabSearch),
                  Tab(text: l.velourTabLibrary),
                ],
              ),
            ),
          ],
          body: TabBarView(controller: _tabs, children: [
            _NowPlayingTab(hostId: widget.hostId, onSearch: () => _tabs.animateTo(2)),
            _QueueTab(hostId: widget.hostId),
            _SearchTab(hostId: widget.hostId),
            _LibraryTab(hostId: widget.hostId),
          ]),
        ),
      ),
      bottomNavigationBar: _tabs.index == 0 ? null : VelourMiniPlayer(hostId: widget.hostId, onTap: () => _tabs.animateTo(0)),
    );
  }
}

// =====================================================================
// shared pieces

const _pad = EdgeInsets.fromLTRB(TiphysTokens.gutter, 12, TiphysTokens.gutter, 32);

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
            : Image.network(url!, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => placeholder),
      ),
    );
  }
}

/// Error card; "Velour unreachable" explains how to turn the socket on.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onRetry});
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

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text, this.hint, this.action});
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

const _loading = Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));

/// One song row: cover, title, artists · length; tap plays, the ⋮ button opens the song menu.
class VelourTrackTile extends StatelessWidget {
  const VelourTrackTile({super.key, required this.hostId, required this.track, this.onTap, this.current = false, this.index, this.trailing});
  final String hostId;
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
                    onPressed: () => showVelourTrackMenu(context, hostId, track),
                  ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Song menu: play next, add to queue, radio, add to playlist, like, go to artist/album.
Future<void> showVelourTrackMenu(BuildContext context, String hostId, VTrack track) {
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

Future<String?> _askName(BuildContext context, String title) {
  final l = AppLocalizations.of(context);
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) {
      void submit() {
        final v = c.text.trim();
        if (v.isNotEmpty) Navigator.of(d).pop(v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 150,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: l.velourPlaylistName),
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(), child: Text(l.commonCancel)),
          FilledButton(onPressed: submit, child: Text(l.commonCreate)),
        ],
      );
    },
  ).whenComplete(c.dispose);
}

/// Route name of pages opened from the Velour screen (the mini player pops back through them).
const _pageRoute = 'velour-page';

void openVelourPage(BuildContext context, String hostId, VSource source, String title) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    settings: const RouteSettings(name: _pageRoute),
    builder: (_) => VelourPageScreen(hostId: hostId, source: source, title: title),
  ));
}

// =====================================================================
// mini player

class VelourMiniPlayer extends ConsumerWidget {
  const VelourMiniPlayer({super.key, required this.hostId, required this.onTap});
  final String hostId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = ref.watch(velourStateProvider(hostId)).value;
    final track = s?.track;
    if (s == null || track == null) return const SizedBox.shrink();
    final len = s.length;
    final pos = s.positionAt(ref.read(clockProvider)());
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
        child: TCard(
          padding: EdgeInsets.zero,
          onTap: onTap,
          semanticLabel: '${l.velourTabNowPlaying}: ${track.title}',
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (len > 0)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(TiphysTokens.radiusCard)),
                child: LinearProgressIndicator(value: (pos / len).clamp(0, 1).toDouble(), minHeight: 2.5, backgroundColor: Colors.transparent),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(children: [
                VelourArt(url: track.thumbnail, size: 40, radius: 8),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(track.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(track.artistLine, style: TextStyle(color: t.textSecondary, fontSize: 12.5), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                IconButton(
                  tooltip: s.playing ? l.mediaPause : l.mediaPlay,
                  icon: Icon(s.playing ? LucideIcons.pause : LucideIcons.play),
                  onPressed: () => velourAct(ref, context, hostId, {'op': 'toggle'}),
                ),
                IconButton(tooltip: l.mediaNext, icon: const Icon(LucideIcons.skipForward), onPressed: () => velourAct(ref, context, hostId, {'op': 'next'})),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// =====================================================================
// now playing

class _NowPlayingTab extends ConsumerStatefulWidget {
  const _NowPlayingTab({required this.hostId, required this.onSearch});
  final String hostId;
  final VoidCallback onSearch;
  @override
  ConsumerState<_NowPlayingTab> createState() => _NowPlayingTabState();
}

class _NowPlayingTabState extends ConsumerState<_NowPlayingTab> {
  double? _seekDrag;
  double? _volDrag;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Advance the position bar once a second while playing.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(velourStateProvider(widget.hostId)).value?.playing == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _act(Map<String, Object?> op) => velourAct(ref, context, widget.hostId, op);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(velourStateProvider(widget.hostId));
    return ListView(padding: _pad, children: [
      ...state.when(
        skipLoadingOnRefresh: true,
        skipLoadingOnReload: true,
        loading: () => [_loading],
        error: (e, _) => [_ErrorCard(error: e, onRetry: () => ref.invalidate(velourStateProvider(widget.hostId)))],
        data: (s) => s.track == null
            ? [
                _Empty(
                  icon: LucideIcons.music,
                  text: l.velourNothingPlaying,
                  hint: l.velourNothingHint,
                  action: TextButton(onPressed: widget.onSearch, child: Text(l.velourTabSearch)),
                ),
              ]
            : _player(context, s),
      ),
    ]);
  }

  List<Widget> _player(BuildContext context, VState s) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final track = s.track!;
    final len = s.length;
    final pos = _seekDrag ?? s.positionAt(ref.read(clockProvider)());
    final sub = [track.artistLine, ?track.album?.name].where((x) => x.isNotEmpty).join(' · ');
    final (repeatIcon, repeatLabel, nextRepeat) = switch (s.repeat) {
      'all' => (LucideIcons.repeat, l.velourRepeatAll, 'one'),
      'one' => (LucideIcons.repeat1, l.velourRepeatOne, 'off'),
      _ => (LucideIcons.repeat, l.velourRepeatOff, 'all'),
    };
    final vol = _volDrag ?? s.volume;
    return [
      TCard(
        radius: TiphysTokens.radiusHero,
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
        child: Column(children: [
          LayoutBuilder(builder: (c, box) => VelourArt(url: track.thumbnail, size: box.maxWidth.clamp(120, 280).toDouble(), radius: 20)),
          const SizedBox(height: 16),
          Text(track.title, style: tt.titleLarge, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(sub, style: tt.bodyMedium?.copyWith(color: t.textSecondary), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
          if (len > 0) ...[
            const SizedBox(height: 8),
            Slider(
              value: pos.clamp(0, len).toDouble(),
              max: len,
              semanticFormatterCallback: (v) => l.mediaPositionOf(mediaTime(v), mediaTime(len)),
              onChanged: (v) => setState(() => _seekDrag = v),
              onChangeEnd: (v) async {
                await _act({'op': 'seek', 'seconds': v});
                if (mounted) setState(() => _seekDrag = null);
              },
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
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(
              tooltip: l.velourShuffle,
              isSelected: s.shuffle,
              color: s.shuffle ? t.accent : t.textSecondary,
              icon: const Icon(LucideIcons.shuffle),
              onPressed: () => _act({'op': 'shuffle', 'on': !s.shuffle}),
            ),
            IconButton(tooltip: l.mediaPrevious, iconSize: 28, icon: const Icon(LucideIcons.skipBack), onPressed: () => _act({'op': 'prev'})),
            Semantics(
              button: true,
              label: s.playing ? l.mediaPause : l.mediaPlay,
              child: Material(
                color: t.isDark ? t.tabActive : const Color(0xFF111114),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _act({'op': 'toggle'}),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: s.loading
                        ? Padding(padding: const EdgeInsets.all(20), child: CircularProgressIndicator(strokeWidth: 2.5, color: t.isDark ? Colors.black : Colors.white))
                        : Icon(s.playing ? LucideIcons.pause : LucideIcons.play, size: 28, color: t.isDark ? Colors.black : Colors.white),
                  ),
                ),
              ),
            ),
            IconButton(tooltip: l.mediaNext, iconSize: 28, icon: const Icon(LucideIcons.skipForward), onPressed: () => _act({'op': 'next'})),
            IconButton(
              tooltip: repeatLabel,
              isSelected: s.repeat != 'off',
              color: s.repeat != 'off' ? t.accent : t.textSecondary,
              icon: Icon(repeatIcon),
              onPressed: () => _act({'op': 'repeat', 'mode': nextRepeat}),
            ),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TCard(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            onTap: () => _act({'op': 'rate', 'videoId': track.videoId, 'like': track.liked ? 'indifferent' : 'like'}),
            semanticLabel: track.liked ? l.velourUnlike : l.velourLike,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(LucideIcons.heart, color: track.liked ? t.danger : t.text),
              const SizedBox(width: 8),
              Flexible(child: Text(track.liked ? l.velourLiked : l.velourLike, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TCard(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VelourLyricsScreen(hostId: widget.hostId))),
            semanticLabel: l.velourLyrics,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(LucideIcons.micVocal),
              const SizedBox(width: 8),
              Flexible(child: Text(l.velourLyrics, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      TCard(
        padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
        child: Row(children: [
          IconButton(
            tooltip: s.muted ? l.mediaUnmute : l.mediaMute,
            icon: Icon(s.muted ? LucideIcons.volumeX : (vol < 40 ? LucideIcons.volume1 : LucideIcons.volume2), color: s.muted ? t.danger : t.text),
            onPressed: () => _act({'op': 'mute', 'on': !s.muted}),
          ),
          Expanded(
            child: Slider(
              value: vol.clamp(0, 100).toDouble(),
              max: 100,
              divisions: 20,
              label: '%${vol.round()}',
              semanticFormatterCallback: (v) => '${l.mediaVolume} %${v.round()}',
              onChanged: (v) => setState(() => _volDrag = v),
              onChangeEnd: (v) async {
                await _act({'op': 'volume', 'percent': v.roundToDouble()});
                if (mounted) setState(() => _volDrag = null);
              },
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(s.muted ? l.mediaMuted : '%${vol.round()}',
                textAlign: TextAlign.end, style: TextStyle(color: t.textSecondary, fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ]),
      ),
    ];
  }
}

// =====================================================================
// lyrics

class VelourLyricsScreen extends ConsumerStatefulWidget {
  const VelourLyricsScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<VelourLyricsScreen> createState() => _VelourLyricsScreenState();
}

class _VelourLyricsScreenState extends ConsumerState<VelourLyricsScreen> {
  final _keys = <int, GlobalKey>{};
  int? _shown;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Synced lines move with the song: redraw four times a second while playing.
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && ref.read(velourStateProvider(widget.hostId)).value?.playing == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _follow(int? line) {
    if (line == null || line == _shown) return;
    _shown = line;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _keys[line]?.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: 0.4, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = ref.watch(velourStateProvider(widget.hostId)).value;
    final track = s?.track;
    final lyrics = track == null ? null : ref.watch(velourLyricsProvider((widget.hostId, track.videoId)));
    final children = <Widget>[
      if (track != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(children: [
            VelourArt(url: track.thumbnail, size: 52, radius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(track.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(track.artistLine, style: TextStyle(color: t.textSecondary, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        ),
      if (track == null)
        _Empty(icon: LucideIcons.music, text: l.velourNothingPlaying)
      else
        ...lyrics!.when(
          loading: () => [_loading],
          error: (e, _) => [_ErrorCard(error: e, onRetry: () => ref.invalidate(velourLyricsProvider((widget.hostId, track.videoId))))],
          data: (ly) {
            if (ly.kind == 'synced' && ly.lines.isNotEmpty) {
              final active = ly.activeLine(s!.positionAt(ref.read(clockProvider)()));
              _follow(active);
              return [
                for (var i = 0; i < ly.lines.length; i++)
                  InkWell(
                    key: _keys.putIfAbsent(i, GlobalKey.new),
                    borderRadius: BorderRadius.circular(10),
                    // Tap a line to jump there.
                    onTap: () => velourAct(ref, context, widget.hostId, {'op': 'seek', 'seconds': ly.lines[i].$1}),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        // Based on the theme's style so the app font is kept (this replaces the inherited style).
                        style: Theme.of(context).textTheme.titleLarge!.copyWith(
                          fontSize: 22,
                          height: 1.3,
                          fontWeight: FontWeight.w800,
                          color: i == active ? t.text : t.textSecondary.withValues(alpha: i < (active ?? -1) ? 0.55 : 0.8),
                        ),
                        // An instrumental gap gets a note icon (♪ isn't in the app font).
                        child: ly.lines[i].$2.isEmpty
                            ? Align(alignment: Alignment.centerLeft, child: Icon(LucideIcons.music, size: 20, color: t.textSecondary))
                            : Text(ly.lines[i].$2),
                      ),
                    ),
                  ),
                if (ly.source != null) _source(context, ly.source!),
              ];
            }
            if (ly.kind == 'plain' && (ly.text ?? '').trim().isNotEmpty) {
              return [
                SelectableText(ly.text!, style: const TextStyle(fontSize: 17, height: 1.5)),
                if (ly.source != null) _source(context, ly.source!),
              ];
            }
            return [_Empty(icon: LucideIcons.micVocal, text: l.velourLyricsNone)];
          },
        ),
    ];
    return SettingsPage(title: l.velourLyrics, children: children);
  }

  Widget _source(BuildContext context, String source) => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Text(AppLocalizations.of(context).velourLyricsSource(source), style: Theme.of(context).textTheme.bodySmall),
      );
}

// =====================================================================
// queue

class _QueueTab extends ConsumerStatefulWidget {
  const _QueueTab({required this.hostId});
  final String hostId;
  @override
  ConsumerState<_QueueTab> createState() => _QueueTabState();
}

class _QueueTabState extends ConsumerState<_QueueTab> {
  /// Shown order while a reorder/removal is on its way (so the row doesn't jump back).
  List<VTrack>? _pending;

  Future<void> _change(Map<String, Object?> op, List<VTrack> optimistic, {String? done}) async {
    setState(() => _pending = optimistic);
    await velourAct(ref, context, widget.hostId, op, done: done);
    if (!mounted) return;
    ref.invalidate(velourQueueProvider(widget.hostId));
    setState(() => _pending = null);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final q = ref.watch(velourQueueProvider(widget.hostId));
    return q.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => _loading,
      error: (e, _) => ListView(padding: _pad, children: [_ErrorCard(error: e, onRetry: () => ref.invalidate(velourQueueProvider(widget.hostId)))]),
      data: (queue) {
        final tracks = _pending ?? queue.tracks;
        if (tracks.isEmpty) return ListView(padding: _pad, children: [_Empty(icon: LucideIcons.listMusic, text: l.velourQueueEmpty)]);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter + 4, 10, TiphysTokens.gutter - 4, 0),
            child: Row(children: [
              Expanded(
                child: Text(
                  [l.velourQueueCount(tracks.length), if (queue.radio) l.velourQueueRadio].join(' · '),
                  style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton.icon(
                icon: const Icon(LucideIcons.listX, size: 18),
                label: Text(l.velourQueueClear),
                onPressed: tracks.length < 2
                    ? null
                    : () async {
                        if (!await confirmDialog(context, message: l.velourQueueClearConfirm, confirmLabel: l.velourQueueClear, destructive: true)) return;
                        if (!context.mounted) return;
                        final keep = [if (queue.index != null && queue.index! < tracks.length) tracks[queue.index!]];
                        await _change({'op': 'clear'}, keep);
                      },
              ),
            ]),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter - 8, 4, TiphysTokens.gutter - 8, 32),
              buildDefaultDragHandles: false,
              itemCount: tracks.length,
              onReorderItem: (from, to) {
                if (to == from) return;
                final next = [...tracks];
                next.insert(to, next.removeAt(from));
                _change({'op': 'move', 'from': from, 'to': to}, next);
              },
              itemBuilder: (context, i) {
                final tr = tracks[i];
                final current = _pending == null && i == queue.index;
                return Dismissible(
                  key: ValueKey('q$i-${tr.videoId}'),
                  direction: current ? DismissDirection.none : DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    decoration: BoxDecoration(color: t.danger, borderRadius: BorderRadius.circular(12)),
                    child: Icon(LucideIcons.trash2, color: Colors.white, semanticLabel: l.velourRemove),
                  ),
                  onDismissed: (_) => _change({'op': 'remove', 'index': i}, [...tracks]..removeAt(i), done: l.velourRemoved),
                  child: VelourTrackTile(
                    hostId: widget.hostId,
                    track: tr,
                    current: current,
                    onTap: () => velourAct(ref, context, widget.hostId, {'op': 'jump', 'index': i}),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: l.velourMore,
                        icon: Icon(LucideIcons.ellipsisVertical, color: t.textSecondary),
                        onPressed: () => showVelourTrackMenu(context, widget.hostId, tr),
                      ),
                      ReorderableDragStartListener(
                        index: i,
                        child: Semantics(
                          label: l.velourReorder,
                          child: Padding(padding: const EdgeInsets.all(12), child: Icon(LucideIcons.gripVertical, color: t.textSecondary)),
                        ),
                      ),
                    ]),
                  ),
                );
              },
            ),
          ),
        ]);
      },
    );
  }
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
          error: (e, _) => [_ErrorCard(error: e, onRetry: () => ref.invalidate(velourPageProvider(key)))],
          data: (fetched) {
            final page = _more ?? fetched;
            return [
              if (widget.showHeader && page.header != null) _PageHeader(hostId: widget.hostId, page: page),
              if (page.isEmpty) _Empty(icon: LucideIcons.searchX, text: widget.source.op == 'search' ? l.commonNothingFound : l.commonEmpty),
              for (final s in page.sections)
                if (s.items.isNotEmpty) _Section(hostId: widget.hostId, section: s),
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
  const _Section({required this.hostId, required this.section});
  final String hostId;
  final VSection section;

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
      bottomNavigationBar: VelourMiniPlayer(hostId: hostId, onTap: () => Navigator.of(context).popUntil((r) => r.settings.name != _pageRoute)),
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
        _Empty(icon: LucideIcons.search, text: l.velourSearchStart, hint: l.velourSearchStartHint),
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
