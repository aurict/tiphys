// Velour full player: a dark backdrop in the cover's colour, the cover (swipe = next/previous, double-tap = like),
// title, seek bar, controls and Up next · Lyrics · PC as a panel. Opens from the mini player, closes with a swipe down.
part of 'velour_screen.dart';

/// Route name of the full player (pages opened from it pop back to the browsing screens first).
const velourPlayerRoute = 'velour-player';

/// Player colours: always dark (white text on a darkened cover tone, well above 7:1).
const _onPlayer = Colors.white;
const _onPlayerSoft = Color(0xB3FFFFFF);
const _likeColor = Color(0xFFFF375F);

void openVelourPlayer(BuildContext context, String hostId) {
  final still = MediaQuery.disableAnimationsOf(context);
  Navigator.of(context).push(PageRouteBuilder<void>(
    settings: const RouteSettings(name: velourPlayerRoute),
    transitionDuration: still ? Duration.zero : const Duration(milliseconds: 340),
    reverseTransitionDuration: still ? Duration.zero : const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => VelourPlayerScreen(hostId: hostId),
    transitionsBuilder: (_, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
      child: child,
    ),
  ));
}

/// The player's own dark theme (sheets opened from it use it too).
ThemeData _playerTheme() => buildTheme(TiphysTokens.dark);

class VelourPlayerScreen extends ConsumerStatefulWidget {
  const VelourPlayerScreen({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<VelourPlayerScreen> createState() => _VelourPlayerScreenState();
}

class _VelourPlayerScreenState extends ConsumerState<VelourPlayerScreen> {
  double? _seekDrag;
  Timer? _tick;

  /// Swipe-down-to-close offset.
  double _dy = 0;

  @override
  void initState() {
    super.initState();
    // Advance the position once a second while playing.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(velourStateProvider(widget.hostId)).value?.playing == true) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _act(Map<String, Object?> op, {VState Function(VState s, DateTime now)? optimistic, String? done}) =>
      velourAct(ref, context, widget.hostId, op, optimistic: optimistic, done: done);

  void _like(VTrack track) {
    final like = track.liked ? 'indifferent' : 'like';
    _act({'op': 'rate', 'videoId': track.videoId, 'like': like}, optimistic: (s, now) => s.copyWith(now, like: like));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(velourStateProvider(widget.hostId));
    final s = state.value;
    final track = s?.track;
    final cover = track?.thumbnail;
    final tone = playerTone((cover == null ? null : ref.watch(velourCoverColorProvider(cover)).value) ?? TiphysTokens.dark.accent);
    final still = MediaQuery.disableAnimationsOf(context);
    final host = ref.watch(profileProvider).host(widget.hostId);

    final Widget content;
    if (s == null || track == null) {
      content = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: state.hasError
              ? VelourErrorCard(error: state.error!, onRetry: () => ref.read(velourStateProvider(widget.hostId).notifier).retry())
              : state.isLoading
                  ? const CircularProgressIndicator(color: _onPlayer)
                  : VelourEmpty(icon: LucideIcons.music, text: l.velourNothingPlaying, hint: l.velourNothingHint),
        ),
      );
    } else {
      content = LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth > box.maxHeight && box.maxWidth > 560;
        final top = _TopBar(hostId: widget.hostId, track: track, hostName: host?.name);
        final info = _TrackInfo(track: track, onLike: () => _like(track));
        final seek = _seekBar(context, s);
        final controls = _Controls(hostId: widget.hostId, state: s, act: _act);
        final extras = _PlayerExtras(hostId: widget.hostId, state: s);
        if (wide) {
          return Column(children: [
            top,
            Expanded(
              child: Row(children: [
                Expanded(
                  flex: 5,
                  child: Padding(padding: const EdgeInsets.fromLTRB(24, 4, 12, 16), child: _Cover(hostId: widget.hostId, track: track, onLike: () => _like(track), act: _act)),
                ),
                Expanded(
                  flex: 6,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 24, 8),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [info, const SizedBox(height: 4), seek, controls, const SizedBox(height: 4), extras]),
                  ),
                ),
              ]),
            ),
          ]);
        }
        return Column(children: [
          top,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(26, 8, 26, 12),
              child: _Cover(hostId: widget.hostId, track: track, onLike: () => _like(track), act: _act),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Column(children: [info, const SizedBox(height: 6), seek, const SizedBox(height: 2), controls, const SizedBox(height: 10), extras, const SizedBox(height: 10)]),
          ),
        ]);
      });
    }

    return Theme(
      data: _playerTheme(),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: GestureDetector(
          // Swipe down anywhere outside the controls closes the player.
          onVerticalDragUpdate: (d) => setState(() => _dy = (_dy + d.delta.dy).clamp(0, 400).toDouble()),
          onVerticalDragEnd: (d) {
            if (_dy > 140 || (d.primaryVelocity ?? 0) > 900) {
              Navigator.of(context).maybePop();
            } else {
              setState(() => _dy = 0);
            }
          },
          child: Transform.translate(
            offset: Offset(0, _dy),
            child: Scaffold(
              backgroundColor: Colors.black,
              body: Stack(fit: StackFit.expand, children: [
                _Backdrop(cover: cover, tone: tone, animate: !still),
                SafeArea(child: content),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _seekBar(BuildContext context, VState s) {
    final l = AppLocalizations.of(context);
    final len = s.length;
    final pos = _seekDrag ?? s.positionAt(ref.read(clockProvider)());
    const time = TextStyle(color: _onPlayerSoft, fontSize: 12, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]);
    return Column(children: [
      SliderTheme(
        data: SliderThemeData(
          trackHeight: 4,
          activeTrackColor: _onPlayer,
          inactiveTrackColor: _onPlayer.withValues(alpha: 0.22),
          thumbColor: _onPlayer,
          overlayColor: _onPlayer.withValues(alpha: 0.12),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          trackShape: const RoundedRectSliderTrackShape(),
        ),
        child: Slider(
          value: len > 0 ? pos.clamp(0, len).toDouble() : 0,
          max: len > 0 ? len : 1,
          semanticFormatterCallback: (v) => l.mediaPositionOf(mediaTime(v), mediaTime(len)),
          onChanged: len > 0 ? (v) => setState(() => _seekDrag = v) : null,
          onChangeEnd: (v) async {
            await _act({'op': 'seek', 'seconds': v}, optimistic: (s, now) => s.copyWith(now, position: v));
            if (mounted) setState(() => _seekDrag = null);
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(children: [
          Text(mediaTime(pos), style: time),
          const Spacer(),
          Text(len > 0 ? mediaTime(len) : '–:––', style: time),
        ]),
      ),
    ]);
  }
}

/// Darkened cover tone with the blurred cover over it, fading to black at the bottom.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.cover, required this.tone, required this.animate});
  final String? cover;
  final Color tone;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      AnimatedContainer(
        duration: animate ? const Duration(milliseconds: 600) : Duration.zero,
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [tone, Color.lerp(tone, Colors.black, 0.82)!]),
        ),
      ),
      if (cover != null)
        ExcludeSemantics(
          child: Opacity(
            opacity: 0.32,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 50, sigmaY: 50, tileMode: TileMode.decal),
              child: Image.network(cover!, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink()),
            ),
          ),
        ),
      // Keeps the lower half (text, controls) dark enough whatever the cover is.
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x33000000), Color(0x14000000), Color(0x99000000), Color(0xE6000000)],
            stops: [0, 0.35, 0.7, 1],
          ),
        ),
      ),
    ]);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.hostId, required this.track, required this.hostName});
  final String hostId;
  final VTrack track;
  final String? hostName;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
      child: Row(children: [
        IconButton(
          tooltip: l.velourClosePlayer,
          iconSize: 28,
          color: _onPlayer,
          icon: const Icon(LucideIcons.chevronDown),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Column(children: [
            Text(l.velourTabNowPlaying.toUpperCase(), style: const TextStyle(color: _onPlayerSoft, fontSize: 11, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
            if (hostName != null)
              Text(l.velourPlayingOn(hostName!), style: const TextStyle(color: _onPlayer, fontSize: 13.5, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        IconButton(
          tooltip: l.velourMore,
          color: _onPlayer,
          icon: const Icon(LucideIcons.ellipsisVertical),
          onPressed: () => showVelourTrackMenu(context, hostId, track),
        ),
      ]),
    );
  }
}

/// The cover: swipe left/right = next/previous, double-tap = like (with a heart pop unless motion is reduced).
class _Cover extends StatefulWidget {
  const _Cover({required this.hostId, required this.track, required this.onLike, required this.act});
  final String hostId;
  final VTrack track;
  final VoidCallback onLike;
  final Future<void> Function(Map<String, Object?> op, {VState Function(VState s, DateTime now)? optimistic, String? done}) act;
  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> with SingleTickerProviderStateMixin {
  double _dx = 0;
  late final AnimationController _heart = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));

  @override
  void dispose() {
    _heart.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(builder: (context, box) {
      final size = (box.maxWidth < box.maxHeight ? box.maxWidth : box.maxHeight).clamp(120.0, 520.0);
      return Center(
        child: Semantics(
          hint: l.velourSwipeHint,
          child: GestureDetector(
            onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx),
            onHorizontalDragEnd: (d) {
              final v = d.primaryVelocity ?? 0;
              if (_dx < -70 || v < -600) widget.act({'op': 'next'});
              if (_dx > 70 || v > 600) widget.act({'op': 'prev'});
              setState(() => _dx = 0);
            },
            onDoubleTap: () {
              if (!widget.track.liked) widget.onLike();
              if (!still) _heart.forward(from: 0);
            },
            child: AnimatedSlide(
              offset: Offset((_dx / size).clamp(-0.25, 0.25), 0),
              duration: _dx == 0 && !still ? const Duration(milliseconds: 200) : Duration.zero,
              curve: Curves.easeOutCubic,
              child: Stack(alignment: Alignment.center, children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, 18))],
                  ),
                  child: Hero(tag: velourArtHero(widget.hostId), child: VelourArt(url: widget.track.thumbnail, size: size, radius: 18)),
                ),
                // Heart pop on double-tap.
                IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _heart,
                    builder: (_, _) {
                      final v = _heart.value;
                      if (v == 0 || v == 1) return const SizedBox.shrink();
                      final scale = Curves.elasticOut.transform((v * 1.6).clamp(0, 1));
                      return Opacity(
                        opacity: v < 0.7 ? 1 : (1 - v) / 0.3,
                        child: Transform.scale(scale: scale, child: const Icon(LucideIcons.heart, size: 96, color: _onPlayer, fill: 1)),
                      );
                    },
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.track, required this.onLike});
  final VTrack track;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sub = [track.artistLine, ?track.album?.name].where((x) => x.isNotEmpty).join(' · ');
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(track.title, style: const TextStyle(color: _onPlayer, fontSize: 23, fontWeight: FontWeight.w800, height: 1.2), maxLines: 2, overflow: TextOverflow.ellipsis),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(sub, style: const TextStyle(color: _onPlayerSoft, fontSize: 15.5, fontWeight: FontWeight.w500), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ]),
      ),
      IconButton(
        tooltip: track.liked ? l.velourUnlike : l.velourLike,
        isSelected: track.liked,
        iconSize: 28,
        icon: Icon(LucideIcons.heart, color: track.liked ? _likeColor : _onPlayer, fill: track.liked ? 1 : 0),
        onPressed: onLike,
      ),
    ]);
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.hostId, required this.state, required this.act});
  final String hostId;
  final VState state;
  final Future<void> Function(Map<String, Object?> op, {VState Function(VState s, DateTime now)? optimistic, String? done}) act;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = state;
    final (repeatIcon, repeatLabel, nextRepeat) = switch (s.repeat) {
      'all' => (LucideIcons.repeat, l.velourRepeatAll, 'one'),
      'one' => (LucideIcons.repeat1, l.velourRepeatOne, 'off'),
      _ => (LucideIcons.repeat, l.velourRepeatOff, 'all'),
    };
    Widget toggle(IconData icon, String label, bool on, VoidCallback tap) => IconButton(
          tooltip: label,
          isSelected: on,
          iconSize: 24,
          color: on ? _onPlayer : _onPlayerSoft,
          // A dot under an active toggle (state isn't shown by colour alone).
          icon: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon),
            const SizedBox(height: 3),
            Container(width: 4, height: 4, decoration: BoxDecoration(shape: BoxShape.circle, color: on ? _onPlayer : Colors.transparent)),
          ]),
          onPressed: tap,
        );
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      toggle(LucideIcons.shuffle, l.velourShuffle, s.shuffle, () => act({'op': 'shuffle', 'on': !s.shuffle}, optimistic: (x, now) => x.copyWith(now, shuffle: !s.shuffle))),
      IconButton(tooltip: l.mediaPrevious, iconSize: 34, color: _onPlayer, icon: const Icon(LucideIcons.skipBack, fill: 1), onPressed: () => act({'op': 'prev'})),
      Semantics(
        button: true,
        label: s.playing ? l.mediaPause : l.mediaPlay,
        child: Material(
          color: _onPlayer,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => act({'op': 'toggle'}, optimistic: (x, now) => x.copyWith(now, playing: !s.playing)),
            child: SizedBox(
              width: 72,
              height: 72,
              child: s.loading
                  ? const Padding(padding: EdgeInsets.all(23), child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black))
                  : Icon(s.playing ? LucideIcons.pause : LucideIcons.play, size: 32, color: Colors.black, fill: 1),
            ),
          ),
        ),
      ),
      IconButton(tooltip: l.mediaNext, iconSize: 34, color: _onPlayer, icon: const Icon(LucideIcons.skipForward, fill: 1), onPressed: () => act({'op': 'next'})),
      toggle(repeatIcon, repeatLabel, s.repeat != 'off', () => act({'op': 'repeat', 'mode': nextRepeat}, optimistic: (x, now) => x.copyWith(now, repeat: nextRepeat))),
    ]);
  }
}

/// Bottom row: PC panel, sleep timer, lyrics, up next.
class _PlayerExtras extends StatelessWidget {
  const _PlayerExtras({required this.hostId, required this.state});
  final String hostId;
  final VState state;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sleeping = state.sleep != null;
    Widget item(IconData icon, String label, VoidCallback onTap, {bool on = false}) => Expanded(
          child: Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icon, size: 22, color: on ? _onPlayer : _onPlayerSoft, fill: on ? 1 : 0),
                  const SizedBox(height: 4),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: on ? _onPlayer : _onPlayerSoft, fontSize: 11.5, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        );
    return Row(children: [
      item(LucideIcons.monitorSpeaker, l.velourPc, () => showVelourPanel(context, hostId, VelourPanelTab.pc)),
      item(LucideIcons.moon, sleeping ? _sleepShort(context, state.sleep!) : l.velourSleepShort, () => showVelourSleepSheet(context, hostId), on: sleeping),
      item(LucideIcons.micVocal, l.velourLyrics, () => showVelourPanel(context, hostId, VelourPanelTab.lyrics)),
      item(LucideIcons.listMusic, l.velourTabQueue, () => showVelourPanel(context, hostId, VelourPanelTab.queue)),
    ]);
  }
}

/// "23:40" or "End of song" for a running timer.
String _sleepShort(BuildContext context, VSleep s) => s.endsAt == null
    ? AppLocalizations.of(context).velourSleepEndOfTrack
    : MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(s.endsAt!), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context));

// =====================================================================
// panel: Up next · Lyrics · PC

enum VelourPanelTab { queue, lyrics, pc }

/// Up next / Lyrics / PC as a tall sheet in the player's dark theme.
Future<void> showVelourPanel(BuildContext context, String hostId, VelourPanelTab tab) {
  final dark = _playerTheme();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF15151A),
    builder: (sheet) => Theme(
      data: dark,
      child: SizedBox(
        height: MediaQuery.sizeOf(sheet).height * 0.86,
        child: DefaultTabController(
          length: 3,
          initialIndex: tab.index,
          child: Builder(builder: (context) {
            final l = AppLocalizations.of(context);
            return Column(children: [
              TabBar(
                dividerColor: Colors.transparent,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5),
                tabs: [Tab(text: l.velourTabQueue), Tab(text: l.velourLyrics), Tab(text: l.velourPc)],
              ),
              Expanded(
                child: TabBarView(children: [
                  VelourQueueView(hostId: hostId),
                  VelourLyricsView(hostId: hostId),
                  VelourPcView(hostId: hostId),
                ]),
              ),
            ]);
          }),
        ),
      ),
    ),
  );
}

// =====================================================================
// lyrics (karaoke)

class VelourLyricsView extends ConsumerStatefulWidget {
  const VelourLyricsView({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<VelourLyricsView> createState() => _VelourLyricsViewState();
}

class _VelourLyricsViewState extends ConsumerState<VelourLyricsView> {
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
      if (c != null && c.mounted) {
        final still = MediaQuery.disableAnimationsOf(c);
        Scrollable.ensureVisible(c, alignment: 0.35, duration: still ? Duration.zero : const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final s = ref.watch(velourStateProvider(widget.hostId)).value;
    final track = s?.track;
    final lyrics = track == null ? null : ref.watch(velourLyricsProvider((widget.hostId, track.videoId)));
    final still = MediaQuery.disableAnimationsOf(context);
    final children = <Widget>[
      if (track == null)
        VelourEmpty(icon: LucideIcons.music, text: l.velourNothingPlaying)
      else
        ...lyrics!.when(
          loading: () => [_loading],
          error: (e, _) => [VelourErrorCard(error: e, onRetry: () => ref.invalidate(velourLyricsProvider((widget.hostId, track.videoId))))],
          data: (ly) {
            if (ly.kind == 'synced' && ly.lines.isNotEmpty) {
              final active = ly.activeLine(s!.positionAt(ref.read(clockProvider)()));
              _follow(active);
              return [
                for (var i = 0; i < ly.lines.length; i++)
                  InkWell(
                    key: _keys.putIfAbsent(i, GlobalKey.new),
                    borderRadius: BorderRadius.circular(12),
                    // Tap a line to jump there.
                    onTap: () => velourAct(ref, context, widget.hostId, {'op': 'seek', 'seconds': ly.lines[i].$1},
                        optimistic: (s, now) => s.copyWith(now, position: ly.lines[i].$1)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
                      child: AnimatedDefaultTextStyle(
                        duration: still ? Duration.zero : const Duration(milliseconds: 250),
                        // Based on the theme's style so the app font is kept (this replaces the inherited style).
                        style: Theme.of(context).textTheme.titleLarge!.copyWith(
                          fontSize: i == active ? 27 : 24,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                          color: i == active ? t.text : t.text.withValues(alpha: i < (active ?? -1) ? 0.5 : 0.66),
                        ),
                        // An instrumental gap gets a note icon (♪ isn't in the app font).
                        child: ly.lines[i].$2.isEmpty
                            ? Align(alignment: Alignment.centerLeft, child: Icon(LucideIcons.music, size: 22, color: t.text.withValues(alpha: i == active ? 1 : 0.5)))
                            : Text(ly.lines[i].$2),
                      ),
                    ),
                  ),
                if (ly.source != null) _source(context, ly.source!),
              ];
            }
            if (ly.kind == 'plain' && (ly.text ?? '').trim().isNotEmpty) {
              return [
                SelectableText(ly.text!, style: TextStyle(fontSize: 18, height: 1.55, color: t.text, fontWeight: FontWeight.w600)),
                if (ly.source != null) _source(context, ly.source!),
              ];
            }
            return [VelourEmpty(icon: LucideIcons.micVocal, text: l.velourLyricsNone)];
          },
        ),
    ];
    return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 120), children: children);
  }

  Widget _source(BuildContext context, String source) => Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Text(AppLocalizations.of(context).velourLyricsSource(source), style: Theme.of(context).textTheme.bodySmall),
      );
}

// =====================================================================
// up next

class VelourQueueView extends ConsumerStatefulWidget {
  const VelourQueueView({super.key, required this.hostId});
  final String hostId;
  @override
  ConsumerState<VelourQueueView> createState() => _VelourQueueViewState();
}

class _VelourQueueViewState extends ConsumerState<VelourQueueView> {
  /// Shown order while a reorder/removal is on its way (so the row doesn't jump back).
  List<VTrack>? _pending;

  Future<void> _change(Map<String, Object?> op, List<VTrack> optimistic, {String? done}) async {
    setState(() => _pending = optimistic);
    await velourAct(ref, context, widget.hostId, op, done: done);
    if (!mounted) return;
    ref.invalidate(velourQueueProvider(widget.hostId));
    setState(() => _pending = null);
  }

  Future<void> _saveQueue() async {
    final l = AppLocalizations.of(context);
    final title = await _askName(context, l.velourSaveQueue);
    if (title == null || !mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    if (await velourAct(ref, context, widget.hostId, {'op': 'save-queue', 'title': title}, done: l.velourSavedQueue(title))) {
      container.invalidate(velourPlaylistsProvider(widget.hostId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final q = ref.watch(velourQueueProvider(widget.hostId));
    return q.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => ListView(padding: _pad, children: const [_loading]),
      error: (e, _) => ListView(padding: _pad, children: [VelourErrorCard(error: e, onRetry: () => ref.invalidate(velourQueueProvider(widget.hostId)))]),
      data: (queue) {
        final tracks = _pending ?? queue.tracks;
        if (tracks.isEmpty) return ListView(padding: _pad, children: [VelourEmpty(icon: LucideIcons.listMusic, text: l.velourQueueEmpty)]);
        return Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter + 4, 6, TiphysTokens.gutter - 8, 0),
            child: Row(children: [
              Expanded(
                child: Text(
                  [l.velourQueueCount(tracks.length), if (queue.radio) l.velourQueueRadio].join(' · '),
                  style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(tooltip: l.velourSaveQueue, icon: const Icon(LucideIcons.listPlus, size: 20), onPressed: _saveQueue),
              IconButton(
                tooltip: l.velourQueueClear,
                icon: const Icon(LucideIcons.listX, size: 20),
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
