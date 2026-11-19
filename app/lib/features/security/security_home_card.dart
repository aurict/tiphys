// Home screen "Security" card (optional, Settings › Home screen). One data source (securityFeedProvider), three looks
// chosen in settings: shield (hero with a painted shield), rings (score rings + chips), bars (bullet-bar list).
// The band is always written (number + word), never conveyed by color alone.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';
import '../claude/claude_screen.dart' show relativeTime;
import 'security_data.dart';
import 'security_widgets.dart' show SecChip, securityBandColor;

/// Fixed-height parts must grow with the text scale.
double _s(BuildContext context, double v) => MediaQuery.textScalerOf(context).scale(v);

String securityBandWord(AppLocalizations l, SecurityBand b) => switch (b) {
  SecurityBand.good => l.secBandGood,
  SecurityBand.warn => l.secBandFair,
  SecurityBand.bad => l.secBandWeak,
  SecurityBand.none => l.secScoreNone,
};

/// Worst first (lowest score; machines without a score last).
List<SecurityHostSummary> sortedByRisk(Iterable<SecurityHostSummary> hosts) => [...hosts]..sort((a, b) => (a.score ?? 1000).compareTo(b.score ?? 1000));

/// One line per host for screen readers: name, score, band, counts, changes, "last known".
String securityHostLabel(AppLocalizations l, SecurityHostSummary h) => [
  h.name,
  h.score == null ? l.secScoreNone : l.secScoreSemantic(h.score!),
  if (h.score != null) securityBandWord(l, h.band),
  if (h.counts.critical > 0) l.secSeverityCount(h.counts.critical, l.secSeverityCritical),
  if (h.counts.high > 0) l.secSeverityCount(h.counts.high, l.secSeverityHigh),
  if (h.changes > 0) l.secChangesChip(h.changes),
  if (h.showStale) l.secCardLastKnown,
].join(', ');

class SecurityHomeCard extends ConsumerWidget {
  const SecurityHomeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(profileProvider.select((p) => p.app.securityStyle));
    final agents = ref.watch(securityHostsProvider);
    final feed = ref.watch(securityFeedProvider);
    void retry() {
      ref.invalidate(securityHostsProvider);
      ref.invalidate(securityFeedProvider);
    }

    if (agents.hasValue && agents.value!.isEmpty) {
      return _Frame(
        style: style,
        child: _Message(icon: LucideIcons.shieldOff, setup: true),
      );
    }
    final f = feed.value;
    if (f == null) {
      if (feed.hasError) {
        return _Frame(
          style: style,
          child: _Message(icon: LucideIcons.circleAlert, error: true, onRetry: retry),
        );
      }
      return _Frame(
        style: style,
        child: _Skeleton(style: style),
      );
    }
    final hosts = sortedByRisk(f.hosts);
    if (hosts.isEmpty) {
      return f.errors.isNotEmpty
          ? _Frame(
              style: style,
              child: _Message(icon: LucideIcons.circleAlert, error: true, onRetry: retry),
            )
          : _Frame(
              style: style,
              child: _Message(icon: LucideIcons.shieldOff, none: true),
            );
    }
    final now = ref.watch(clockProvider)();
    final data = _Data(f, hosts, now);
    return _Frame(
      style: style,
      child: switch (style) {
        SecurityStyle.shield => _ShieldBody(data: data),
        SecurityStyle.rings => _RingsBody(data: data),
        SecurityStyle.bars => _BarsBody(data: data),
      },
    );
  }
}

class _Data {
  _Data(this.feed, this.hosts, this.now);
  final SecurityFeed feed;
  final List<SecurityHostSummary> hosts;
  final DateTime now;

  int get changes => feed.changes;
  int get critical => feed.critical;
  int get high => hosts.fold(0, (a, h) => a + h.counts.high);
  bool get anyStale => hosts.any((h) => h.showStale);
  SecurityBand get worst => securityBand(lowest);
  int? get lowest => hosts.firstOrNull?.score;
  bool get allClear => changes == 0 && critical == 0 && high == 0 && worst == SecurityBand.good;

  DateTime? get lastCheck => hosts.map((h) => h.lastOkAt).nonNulls.fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

  String status(AppLocalizations l) => changes > 0 && critical > 0
      ? l.secHomeBoth(changes, critical)
      : changes > 0
      ? l.secHomeChanges(changes)
      : critical > 0
      ? l.secHomeCritical(critical)
      : allClear
      ? l.secCardAllClear
      : securityBandWord(l, worst);

  /// "7 dk önce", or "Son bilinen durum · 7 sa önce" when some machine could not be checked.
  String when(AppLocalizations l) {
    final at = lastCheck;
    final rel = at == null ? l.secNeverChecked : relativeTime(l, at, now);
    return anyStale ? l.secStaleSince(rel) : rel;
  }
}

/// Card shell: tap opens the Security center.
class _Frame extends StatelessWidget {
  const _Frame({required this.style, required this.child});
  final SecurityStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final hero = style == SecurityStyle.shield;
    return TCard(
      radius: hero ? TiphysTokens.radiusHero : TiphysTokens.radiusCard,
      padding: EdgeInsets.zero,
      onTap: () => context.push('/security'),
      child: child,
    );
  }
}

/// Title, last-check time and chevron (shared by every style). Semantic header.
class _Header extends StatelessWidget {
  const _Header({this.when, this.stale = false});
  final String? when;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return Semantics(
      header: true,
      container: true,
      label: [l.secRowTitle, ?when].join(', '),
      excludeSemantics: true,
      child: Row(
        children: [
          Text(
            l.secRowTitle,
            style: tt.titleSmall?.copyWith(color: t.textSecondary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: when == null
                ? const SizedBox.shrink()
                : Text(
                    when!,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: stale ? t.warning : t.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          Icon(LucideIcons.chevronRight, size: 18, color: t.textSecondary),
        ],
      ),
    );
  }
}

/// Runs 0→1 once when first built (600 ms, easeOutCubic); no motion with "remove animations".
class _Reveal extends StatelessWidget {
  const _Reveal({required this.builder});
  final Widget Function(BuildContext context, double progress) builder;

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: still ? 1 : 0, end: 1),
      duration: still ? Duration.zero : const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => builder(context, v),
    );
  }
}

/// A host that opens its own screen.
class _HostTap extends StatelessWidget {
  const _HostTap({required this.host, required this.child, this.radius = 10});
  final SecurityHostSummary host;
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Semantics(
      container: true,
      button: true,
      label: securityHostLabel(l, host),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: () => context.push(securityRoute(host.id, agentId: host.agent.id)),
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// States

class _Message extends StatelessWidget {
  const _Message({required this.icon, this.setup = false, this.error = false, this.none = false, this.onRetry});
  final IconData icon;
  final bool setup, error, none;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final title = setup
        ? l.secCardNotSetUp
        : error
        ? l.secCardError
        : l.secCardNoHosts;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 14, 14),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: _s(context, 120)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: (error ? t.danger : t.textSecondary).withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(icon, size: 20, color: error ? t.danger : t.textSecondary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: tt.titleMedium),
                      if (setup)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(l.secCardNotSetUpHint, style: tt.bodySmall),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (onRetry != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                  onPressed: onRetry,
                  child: Text(l.commonRetry),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Placeholder with the height of the loaded card (no layout shift).
class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.style});
  final SecurityStyle style;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget bar(double w, double h, {double r = 6}) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(color: t.ringTrack, borderRadius: BorderRadius.circular(r)),
    );
    final body = switch (style) {
      SecurityStyle.shield => Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(70, 12),
                const SizedBox(height: 10),
                bar(150, 20),
                const SizedBox(height: 14),
                for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 14), child: bar(120, 12)),
              ],
            ),
          ),
          Container(
            width: 96,
            height: 112,
            decoration: BoxDecoration(color: t.ringTrack, borderRadius: BorderRadius.circular(40)),
          ),
        ],
      ),
      SecurityStyle.rings => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bar(70, 12),
          const SizedBox(height: 14),
          Row(
            children: [
              for (var i = 0; i < 3; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: t.ringTrack, width: 6),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          bar(180, 24, r: 12),
        ],
      ),
      SecurityStyle.bars => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bar(70, 12),
          for (var i = 0; i < 3; i++) ...[const SizedBox(height: 16), bar(110, 12), const SizedBox(height: 8), bar(double.infinity, 8, r: 4)],
        ],
      ),
    };
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 18, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: style == SecurityStyle.bars ? 0 : _s(context, 160)),
          child: body,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// shield

class _ShieldBody extends StatelessWidget {
  const _ShieldBody({required this.data});
  final _Data data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final shown = data.hosts.length > 3 ? data.hosts.take(2).toList() : data.hosts;
    final more = data.hosts.length - shown.length;
    final base = securityBandColor(t, data.worst);
    final w = scale > 1.3 ? 84.0 : 132.0;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: _s(context, 196)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Header(when: data.when(l), stale: data.anyStale),
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.status(l),
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 21, height: 1.15),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      for (final h in shown) _ShieldRow(host: h),
                      if (more > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, top: 4),
                          child: Text(
                            '+$more',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: t.textSecondary),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: _Reveal(
                    builder: (context, p) => SizedBox(
                      width: w,
                      height: w * 1.16,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: ShieldPainter(color: base, dark: t.isDark, progress: p),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.only(bottom: w * 0.1, left: w * 0.26, right: w * 0.26), // inside the tapering shield, at any text size
                            child: Opacity(
                              opacity: p,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  data.lowest == null ? '—' : '${data.lowest}',
                                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.8, color: shieldInk(base, t.isDark)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ShieldRow extends StatelessWidget {
  const _ShieldRow({required this.host});
  final SecurityHostSummary host;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = securityBandColor(t, host.band);
    return _HostTap(
      host: host,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: _s(context, 32)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          child: Row(
            children: [
              StatusDot(color: c, size: 8),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  host.name,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: t.isDark ? const Color(0xFFD1D1D6) : const Color(0xFF3A3A40)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                host.score == null ? '—' : '${host.score} · ${securityBandWord(l, host.band)}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: c),
                maxLines: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Number color on the shield: white or near-black, whichever reads better on the (lightened) face.
Color shieldInk(Color base, bool dark) {
  final face = Color.lerp(base, Colors.white, dark ? 0.2 : 0.16)!;
  const darkInk = Color(0xFF0B0B0F);
  double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  return contrast(Colors.white, face) >= contrast(darkInk, face) ? Colors.white : darkInk;
}

/// Isometric-style shield: ground shadow, glow, thickness (offset back face), lit left face and shaded right face,
/// inner bevel and a highlight. [progress] reveals it from the bottom up.
class ShieldPainter extends CustomPainter {
  ShieldPainter({required this.color, required this.dark, this.progress = 1});
  final Color color;
  final bool dark;
  final double progress;

  static Path _shield() {
    // 100 × 116 box; the center line is x = 50.
    final p = Path()
      ..moveTo(50, 4)
      ..cubicTo(64, 12, 78, 16, 92, 16)
      ..lineTo(92, 54)
      ..cubicTo(92, 84, 72, 104, 50, 112)
      ..cubicTo(28, 104, 8, 84, 8, 54)
      ..lineTo(8, 16)
      ..cubicTo(22, 16, 36, 12, 50, 4)
      ..close();
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    canvas.save();
    canvas.scale(k, size.height / 116);
    const box = Rect.fromLTWH(0, 0, 100, 116);

    // Glow behind (strong in dark, a soft tint in light) and the ground shadow.
    final glow = Rect.fromCenter(center: const Offset(50, 56), width: 118, height: 118);
    canvas.drawOval(
      glow,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: dark ? 0.38 : 0.2),
            color.withValues(alpha: 0),
          ],
        ).createShader(glow),
    );
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(52, 113), width: 62, height: 6),
      Paint()..color = (dark ? color : const Color(0xFF111114)).withValues(alpha: dark ? 0.18 : 0.1),
    );

    // Reveal from the bottom up, with a slight rise.
    final reveal = progress.clamp(0.0, 1.0);
    canvas.clipRect(Rect.fromLTRB(-10, 116 * (1 - reveal), 110, 130));
    canvas.translate(0, (1 - reveal) * 6);

    final shield = _shield();
    // Thickness: the same shape shifted back/right, darker.
    canvas.save();
    canvas.translate(4.5, 3.5);
    canvas.drawPath(shield, Paint()..color = Color.lerp(color, Colors.black, dark ? 0.45 : 0.32)!);
    canvas.restore();

    // Faces: left lit, right in shade.
    canvas.save();
    canvas.clipPath(shield);
    Paint face(Rect r, Color a, Color b) =>
        Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [a, b]).createShader(r);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 50, 116),
      face(box, Color.lerp(color, Colors.white, dark ? 0.34 : 0.26)!, Color.lerp(color, Colors.white, dark ? 0.12 : 0.08)!),
    );
    canvas.drawRect(
      const Rect.fromLTWH(50, 0, 50, 116),
      face(box, Color.lerp(color, Colors.white, dark ? 0.08 : 0.02)!, Color.lerp(color, Colors.black, dark ? 0.28 : 0.2)!),
    );
    canvas.restore();

    // Inner bevel (smaller shield outline) and a highlight on the upper left edge.
    canvas.save();
    canvas.translate(50, 58);
    canvas.scale(0.78);
    canvas.translate(-50, -58);
    canvas.drawPath(
      shield,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = Colors.white.withValues(alpha: dark ? 0.22 : 0.4),
    );
    canvas.restore();
    canvas.drawPath(
      Path()
        ..moveTo(14, 22)
        ..lineTo(14, 52)
        ..cubicTo(14, 62, 17, 70, 21, 77),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.4
        ..color = Colors.white.withValues(alpha: dark ? 0.3 : 0.5),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ShieldPainter o) => o.color != color || o.dark != dark || o.progress != progress;
}

// ---------------------------------------------------------------------------------------------------------------------
// rings

class _RingsBody extends StatelessWidget {
  const _RingsBody({required this.data});
  final _Data data;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final hosts = data.hosts;
    final over = hosts.length > 4;
    final shown = over ? hosts.take(3).toList() : hosts;
    const gap = 8.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _Header(when: data.when(l), stale: data.anyStale),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, box) {
              final scale = MediaQuery.textScalerOf(context).scale(1);
              final cols = ((box.maxWidth + gap) / (72 * scale + gap)).floor().clamp(1, 4);
              final side = ((box.maxWidth - (cols - 1) * gap) / cols).floorToDouble();
              return _Reveal(
                builder: (context, p) => Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  alignment: WrapAlignment.spaceEvenly,
                  children: [
                    for (final h in shown)
                      SizedBox(
                        width: side,
                        child: _RingTile(host: h, progress: p),
                      ),
                    if (over)
                      SizedBox(
                        width: side,
                        child: _MoreTile(count: hosts.length - 3),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (data.changes > 0) SecChip(l.secChangesChip(data.changes), t.warning, icon: LucideIcons.gitCompareArrows),
                if (data.critical > 0) SecChip(l.secSeverityCount(data.critical, l.secSeverityCritical), t.danger, icon: LucideIcons.shieldAlert),
                if (data.high > 0) SecChip(l.secSeverityCount(data.high, l.secSeverityHigh), t.warning, icon: LucideIcons.triangleAlert),
                if (data.changes == 0 && data.critical == 0 && data.high == 0)
                  SecChip(
                    data.allClear ? l.secCardAllClear : securityBandWord(l, data.worst),
                    data.allClear ? t.success : securityBandColor(t, data.worst),
                    icon: data.allClear ? LucideIcons.circleCheck : LucideIcons.info,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingTile extends StatelessWidget {
  const _RingTile({required this.host, required this.progress});
  final SecurityHostSummary host;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = securityBandColor(t, host.band);
    return _HostTap(
      host: host,
      radius: 14,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 58,
              height: 58,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned.fill(child: CustomPaint(painter: _ScoreRingPainter(host.score, c, t.ringTrack, progress))),
                  Padding(
                    padding: const EdgeInsets.all(11),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        host.score == null ? '—' : '${host.score}',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: t.text),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              host.name,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            Text(
              securityBandWord(l, host.band),
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            if (host.showStale)
              Text(
                l.secCardLastKnownShort,
                style: TextStyle(fontSize: 10.5, color: t.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.chipBackground,
                border: Border.all(color: t.separator),
              ),
              child: Text(
                '+$count',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: t.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScoreRingPainter extends CustomPainter {
  _ScoreRingPainter(this.score, this.color, this.track, this.progress);
  final int? score;
  final Color color, track;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 6.0;
    final r = Rect.fromLTWH(w / 2, w / 2, size.width - w, size.height - w);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(r, 0, 2 * math.pi, false, p..color = track);
    if (score != null && score! > 0) {
      canvas.drawArc(r, -math.pi / 2, 2 * math.pi * (score!.clamp(0, 100) / 100) * progress, false, p..color = color);
    }
  }

  @override
  bool shouldRepaint(_ScoreRingPainter o) => o.score != score || o.color != color || o.track != track || o.progress != progress;
}

// ---------------------------------------------------------------------------------------------------------------------
// bars

class _BarsBody extends StatelessWidget {
  const _BarsBody({required this.data});
  final _Data data;

  static const maxRows = 6;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final shown = data.hosts.take(maxRows).toList();
    final more = data.hosts.length - shown.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: _Header(when: data.when(l), stale: data.anyStale),
          ),
          const SizedBox(height: 4),
          _Reveal(
            builder: (context, p) => Column(
              children: [for (final h in shown) _BarRow(host: h, progress: p)],
            ),
          ),
          if (more > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
              child: Text(
                '+$more',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: t.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({required this.host, required this.progress});
  final SecurityHostSummary host;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final c = securityBandColor(t, host.band);
    final stale = host.showStale;
    Widget badge(IconData icon, String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(
            text,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
    return _HostTap(
      host: host,
      radius: 12,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: _s(context, 48)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 7, 4, 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            host.name,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (stale)
                          Flexible(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                l.secCardLastKnownShort,
                                style: TextStyle(fontSize: 11, color: t.textSecondary),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    children: [
                      if (host.counts.critical > 0) badge(LucideIcons.shieldAlert, '${host.counts.critical}', t.danger),
                      if (host.counts.high > 0) badge(LucideIcons.triangleAlert, '${host.counts.high}', t.warning),
                      if (host.changes > 0) badge(LucideIcons.gitCompareArrows, '${host.changes}', t.warning),
                    ],
                  ),
                  // Fixed right-aligned cell: the score column lines up on every row.
                  SizedBox(
                    width: _s(context, 84),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: host.score == null ? '—' : '${host.score}',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: c),
                              ),
                              TextSpan(
                                text: ' ${securityBandWord(l, host.band)}',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: c),
                              ),
                            ],
                          ),
                          maxLines: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Opacity(
                opacity: stale ? 0.55 : 1,
                child: SizedBox(height: 12, child: CustomPaint(painter: BulletBarPainter(host.score, t, progress))),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three qualitative zones (0–59 / 60–84 / 85–100) in low-alpha band colors and a solid marker at the score.
class BulletBarPainter extends CustomPainter {
  BulletBarPainter(this.score, this.t, this.progress);
  final int? score;
  final TiphysTokens t;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const h = 8.0;
    final top = (size.height - h) / 2;
    final w = size.width;
    final clip = RRect.fromRectAndRadius(Rect.fromLTWH(0, top, w, h), const Radius.circular(h / 2));
    canvas.save();
    canvas.clipRRect(clip);
    var x = 0.0;
    for (final (to, color) in [(0.6, t.danger), (0.85, t.warning), (1.0, t.success)]) {
      canvas.drawRect(Rect.fromLTRB(x * w, top, to * w, top + h), Paint()..color = color.withValues(alpha: t.isDark ? 0.28 : 0.2));
      x = to;
    }
    canvas.restore();
    final s = score;
    if (s == null) return;
    final c = securityBandColor(t, securityBand(s));
    final cx = (3 + (w - 6) * (s.clamp(0, 100) / 100)) * progress.clamp(0.0, 1.0) + 3 * (1 - progress);
    final marker = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx.clamp(3, w - 3), size.height / 2), width: 5, height: size.height),
      const Radius.circular(2.5),
    );
    canvas.drawRRect(marker.inflate(1), Paint()..color = t.isDark ? const Color(0xFF1C1C1E) : Colors.white);
    canvas.drawRRect(marker, Paint()..color = c);
  }

  @override
  bool shouldRepaint(BulletBarPainter o) => o.score != score || o.t != t || o.progress != progress;
}
