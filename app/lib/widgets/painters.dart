// The design's drawings: isometric server stack, double-ring gauge, mini chart.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum HostState { online, offline, unknown }

class StackSlab {
  const StackSlab({required this.color, required this.state});
  final Color color;
  final HostState state;
}

/// Stacked isometric server blocks (first host on top). Floats gently; the LED on top blinks.
class IsoStack extends StatefulWidget {
  const IsoStack({super.key, required this.slabs, this.width = 150});
  final List<StackSlab> slabs;
  final double width;

  @override
  State<IsoStack> createState() => _IsoStackState();
}

class _IsoStackState extends State<IsoStack> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final h = widget.width * 175 / 150;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // Floats up and down every 5 s; the LED blinks every 1.6 s.
        final now = DateTime.now().millisecondsSinceEpoch;
        final float = MediaQuery.disableAnimationsOf(context) ? 0.0 : -2.5 + 2.5 * math.cos(2 * math.pi * (now % 5000) / 5000);
        final led = 0.65 + 0.35 * math.cos(2 * math.pi * _c.value);
        return Transform.translate(
          offset: Offset(0, float),
          child: CustomPaint(size: Size(widget.width, h), painter: _IsoPainter(widget.slabs, t, led)),
        );
      },
    );
  }
}

class _IsoPainter extends CustomPainter {
  _IsoPainter(this.slabs, this.t, this.led);
  final List<StackSlab> slabs;
  final TiphysTokens t;
  final double led;

  @override
  void paint(Canvas canvas, Size size) {
    // The design's SVG coordinates (viewBox 26 28 120 140) are scaled.
    canvas.save();
    canvas.scale(size.width / 120, size.height / 140);
    canvas.translate(-26, -28);

    if (t.isDark) {
      final glowColor = slabs.isEmpty ? const Color(0xFFA39DF5) : t.hostColor(slabs.first.color);
      canvas.drawOval(
        Rect.fromCenter(center: const Offset(86, 100), width: 140, height: 132),
        Paint()
          ..shader = RadialGradient(colors: [glowColor.withValues(alpha: 0.35), glowColor.withValues(alpha: 0)])
              .createShader(Rect.fromCenter(center: const Offset(86, 100), width: 140, height: 132)),
      );
    }
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(86, 160), width: 108, height: 14),
      Paint()..color = (t.isDark ? const Color(0xFFA39DF5) : const Color(0xFF111114)).withValues(alpha: t.isDark ? 0.14 : 0.08),
    );

    final items = slabs.isEmpty
        ? List.generate(3, (_) => StackSlab(color: t.isDark ? const Color(0xFF48484A) : const Color(0xFFD1D1D6), state: HostState.unknown))
        : slabs.take(3).toList();
    // Drawn bottom to top; the list is ordered top to bottom.
    for (var i = items.length - 1; i >= 0; i--) {
      final top = 43.0 + 26 * i + (3 - items.length) * 26;
      _slab(canvas, top, items[i], isTop: i == 0);
    }
    canvas.restore();
  }

  void _slab(Canvas canvas, double y, StackSlab s, {required bool isTop}) {
    var base = s.color;
    if (s.state == HostState.offline) base = Color.lerp(base, const Color(0xFF8E8E93), 0.65)!;
    final Color top, left, right;
    if (t.isDark) {
      top = Color.lerp(base, Colors.white, 0.72)!;
      left = base;
      right = Color.lerp(base, Colors.black, 0.25)!;
    } else {
      top = Color.lerp(base, Colors.white, 0.82)!;
      left = Color.lerp(base, Colors.white, 0.4)!;
      right = base;
    }
    Path poly(List<Offset> pts) => Path()..addPolygon(pts, true);
    canvas.drawPath(poly([Offset(86, y), Offset(136, y + 25), Offset(86, y + 50), Offset(36, y + 25)]), Paint()..color = top);
    canvas.drawPath(poly([Offset(36, y + 25), Offset(86, y + 50), Offset(86, y + 66), Offset(36, y + 41)]), Paint()..color = left);
    canvas.drawPath(poly([Offset(86, y + 50), Offset(136, y + 25), Offset(136, y + 41), Offset(86, y + 66)]), Paint()..color = right);

    final ledColor = switch (s.state) {
      HostState.online => const Color(0xFF86EFAC),
      HostState.offline => const Color(0xFFFF6961),
      HostState.unknown => const Color(0xFFFFFFFF),
    };
    canvas.drawCircle(Offset(100, y + 51), 2.2, Paint()..color = Colors.white.withValues(alpha: 0.9));
    canvas.drawCircle(Offset(108, y + 47), isTop ? 2.4 : 2.2, Paint()..color = ledColor.withValues(alpha: isTop ? led : 0.95));
  }

  @override
  bool shouldRepaint(_IsoPainter old) => old.led != led || old.slabs != slabs || old.t != t;
}

/// Two nested rings (outer: CPU, inner: RAM).
class RingGauge extends StatelessWidget {
  const RingGauge({super.key, required this.outer, required this.inner, required this.outerColor, required this.innerColor, this.size = 70});
  final double? outer; // 0..1, null = unknown
  final double? inner;
  final Color outerColor;
  final Color innerColor;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(outer, inner, outerColor, innerColor, context.tokens.ringTrack),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.outer, this.inner, this.oc, this.ic, this.track);
  final double? outer, inner;
  final Color oc, ic, track;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 74;
    final c = Offset(size.width / 2, size.height / 2);
    void ring(double r, double w, double? v, Color color) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * s
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(c, r * s, p..color = track);
      if (v != null && v > 0) {
        canvas.drawArc(Rect.fromCircle(center: c, radius: r * s), -math.pi / 2, 2 * math.pi * v.clamp(0, 1), false, p..color = color);
      }
    }

    ring(30, 9, outer, oc);
    ring(18, 7, inner, ic);
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.outer != outer || o.inner != inner || o.oc != oc || o.ic != ic || o.track != track;
}

/// Mini line chart with a filled area.
class Sparkline extends StatelessWidget {
  const Sparkline({super.key, required this.values, required this.color, this.height = 32});
  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: height, width: double.infinity, child: CustomPaint(painter: _SparkPainter(values, color)));
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.v, this.color);
  final List<double> v;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (v.length < 2) return;
    final lo = v.reduce(math.min), hi = v.reduce(math.max);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    Offset pt(int i) => Offset(size.width * i / (v.length - 1), size.height - 2 - (size.height - 6) * (v[i] - lo) / span);
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.18));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter o) => o.v != v || o.color != color;
}
