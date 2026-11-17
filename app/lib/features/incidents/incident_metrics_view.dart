// Metrics tab of the incident screen (PLAN.md §13.1): the agent's in-memory metrics ring around the opening (host CPU,
// load, memory, swap, disks, and the container's CPU/memory), one small chart per series. A series an evidence chip
// pointed at is highlighted and scrolled into view.
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';
import 'incident_analysis.dart';
import 'incident_texts.dart';

class MetricsView extends StatefulWidget {
  const MetricsView({super.key, required this.metrics, required this.focus});
  final Map<String, dynamic>? metrics;

  /// A `metric:<name>` evidence target to highlight (null otherwise).
  final EvidenceFocus? focus;

  @override
  State<MetricsView> createState() => _MetricsViewState();
}

class _MetricsViewState extends State<MetricsView> {
  final _key = GlobalKey();
  int _shown = -1;

  void _scroll() {
    final f = widget.focus;
    if (f == null || f.nonce == _shown || f.target.kind != 'metric') return;
    _shown = f.nonce;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _key.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, duration: Duration.zero, alignment: 0.1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final series = metricSeries(widget.metrics);
    if (series.isEmpty) return TCard(child: Text(l.incMetricsEmpty));
    _scroll();
    final target = widget.focus?.target;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text(l.incMetricsNote, style: Theme.of(context).textTheme.bodySmall)),
      for (final s in series)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _SeriesCard(key: target?.kind == 'metric' && target?.name == s.name ? _key : null, series: s, highlighted: target?.kind == 'metric' && target?.name == s.name),
        ),
    ]);
  }
}

class _SeriesCard extends StatelessWidget {
  const _SeriesCard({super.key, required this.series, required this.highlighted});
  final MetricSeries series;
  final bool highlighted;

  static String _num(double v) => v.abs() >= 100 ? v.round().toString() : (v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1));

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final hm = DateFormat.Hm(locale);
    final first = series.points.first.$1, last = series.points.last.$1;
    final pctLike = series.name.endsWith('Pct') || series.name == 'host.cpu' || series.name == 'container.cpu' || series.name.startsWith('disk:');
    final title = metricTitle(l, series.name);
    final range = l.incMetricRange(_num(series.min), _num(series.max), _num(series.last));
    return TCard(
      borderColor: highlighted ? t.accent : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: tt.titleSmall),
        Text(range, style: tt.bodySmall),
        const SizedBox(height: 8),
        SizedBox(
          height: 90,
          child: Semantics(
            label: '$title, $range',
            child: ExcludeSemantics(
              child: LineChart(LineChartData(
                minY: 0,
                maxY: pctLike ? (series.max > 100 ? null : 100) : null,
                gridData: FlGridData(drawVerticalLine: false, horizontalInterval: pctLike ? 50 : null, getDrawingHorizontalLine: (_) => FlLine(color: t.separator, strokeWidth: 1)),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(),
                  rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 34,
                      getTitlesWidget: (v, m) => v == m.max || v == m.min ? Text(_num(v), style: TextStyle(fontSize: 10, color: t.textSecondary)) : const SizedBox.shrink(),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 18,
                      interval: (last - first) <= 0 ? 1 : (last - first),
                      getTitlesWidget: (v, m) => Text(hm.format(DateTime.fromMillisecondsSinceEpoch(v.toInt())), style: TextStyle(fontSize: 10, color: t.textSecondary)),
                    ),
                  ),
                ),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: [for (final p in series.points) FlSpot(p.$1, p.$2)],
                    color: highlighted ? t.accent : t.accent.withValues(alpha: 0.85),
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: true, color: t.accent.withValues(alpha: 0.12)),
                  ),
                ],
              )),
            ),
          ),
        ),
      ]),
    );
  }
}
