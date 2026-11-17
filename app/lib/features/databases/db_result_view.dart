// Result display of the database console: the table (horizontal scroll, sticky header, paging, cell detail sheet), the
// truncation banners and the charts of saved queries (table | stat | line | bar, mapped by ChartData).
import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../vault/vault_state.dart' show secureWindowProvider, sensitiveClipboardProvider;
import 'db_data.dart';

/// FLAG_SECURE (no screenshots, blank in the app switcher) while database values are on screen: results, a cell, the
/// write preview, the read-only role SQL (it holds a fresh password) and the connection form. Counted, so a result
/// under a cell sheet doesn't lose it when the sheet closes.
class DbSecure extends ConsumerStatefulWidget {
  const DbSecure({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<DbSecure> createState() => _DbSecureState();
}

class _DbSecureState extends ConsumerState<DbSecure> {
  static int _shown = 0;
  late final Future<void> Function(bool) _secure;

  @override
  void initState() {
    super.initState();
    _secure = ref.read(secureWindowProvider);
    if (_shown++ == 0) unawaited(_secure(true));
  }

  @override
  void dispose() {
    if (--_shown == 0) unawaited(_secure(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A note line with an icon (banner of a truncated result, hints).
class DbNote extends StatelessWidget {
  const DbNote(this.text, {super.key, this.color, this.icon = LucideIcons.circleAlert, this.title});
  final String text;

  /// Bold first line.
  final String? title;
  final Color? color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.tokens.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(TiphysTokens.radiusList),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) Text(title!, style: Theme.of(context).textTheme.titleSmall),
                Text(text, style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Summary line, banners and the paged table of one result.
class DbResultView extends StatelessWidget {
  const DbResultView({super.key, required this.result, this.actions = const []});
  final DbResult result;

  /// Buttons next to the summary (CSV share, save query).
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final tt = Theme.of(context).textTheme;
    final r = result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(l.dbRowsSummary(r.rowCount, r.elapsedMs ?? 0), style: tt.bodySmall)),
            ...actions,
          ],
        ),
        const SizedBox(height: 8),
        if (r.truncated) ...[DbNote(l.dbTruncatedBanner(r.rowCount)), const SizedBox(height: 8)],
        if (r.cellsTruncated > 0) ...[
          DbNote(l.dbCellsTruncated(r.cellsTruncated), icon: LucideIcons.info, color: context.tokens.accent),
          const SizedBox(height: 8),
        ],
        if (r.rows.isEmpty) TCard(child: Text(l.dbNoRows)) else DbResultTable(result: r),
      ],
    );
  }
}

class DbResultTable extends StatefulWidget {
  const DbResultTable({super.key, required this.result});
  final DbResult result;

  @override
  State<DbResultTable> createState() => _DbResultTableState();
}

class _DbResultTableState extends State<DbResultTable> {
  static const _headerH = 38.0, _rowH = 34.0, _maxH = 420.0;
  int _page = 0;
  late List<double> _widths = _computeWidths(widget.result);

  @override
  void didUpdateWidget(DbResultTable old) {
    super.didUpdateWidget(old);
    if (!identical(old.result, widget.result)) {
      _page = 0;
      _widths = _computeWidths(widget.result);
    }
  }

  /// Column width from the header and the first rows (about 8 px per character), within 76..240.
  static List<double> _computeWidths(DbResult r) {
    return [
      for (var i = 0; i < r.columns.length; i++)
        () {
          var chars = r.columns[i].name.length;
          for (final row in r.rows.take(60)) {
            if (i < row.length) chars = math.max(chars, math.min(cellText(row[i]).length, 32));
          }
          return (chars * 8.2 + 28).clamp(76.0, 240.0);
        }(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final r = widget.result;
    final rows = r.page(_page);
    final pages = r.pageCount();
    final total = _widths.fold<double>(0, (a, b) => a + b);
    final height = math.min(_maxH, _headerH + rows.length * _rowH);
    final mono = TextStyle(
      fontFamily: monoFamily,
      fontSize: 12.5,
      color: t.text,
      fontFeatures: const [FontFeature.disable('calt'), FontFeature.disable('liga')],
    );
    return DbSecure(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TCard(
            padding: EdgeInsets.zero,
            radius: TiphysTokens.radiusList,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(TiphysTokens.radiusList),
              child: SizedBox(
                height: height,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: total,
                    child: Column(
                      children: [
                        Container(
                          height: _headerH,
                          color: t.separator.withValues(alpha: 0.35),
                          child: Row(
                            children: [
                              for (var i = 0; i < r.columns.length; i++)
                                SizedBox(
                                  width: _widths[i],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10),
                                    child: Align(
                                      alignment: r.columns[i].kind == 'number' ? Alignment.centerRight : Alignment.centerLeft,
                                      child: Text(
                                        r.columns[i].name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: mono.copyWith(fontWeight: FontWeight.w700),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemExtent: _rowH,
                            itemCount: rows.length,
                            itemBuilder: (context, ri) => DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border(bottom: BorderSide(color: t.separator.withValues(alpha: 0.6))),
                              ),
                              child: Row(
                                children: [
                                  for (var i = 0; i < r.columns.length; i++)
                                    SizedBox(
                                      width: _widths[i],
                                      height: _rowH,
                                      child: InkWell(
                                        onTap: () => showCellSheet(context, r.columns[i], i < rows[ri].length ? rows[ri][i] : null),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          child: Align(
                                            alignment: r.columns[i].kind == 'number' ? Alignment.centerRight : Alignment.centerLeft,
                                            child: i < rows[ri].length && rows[ri][i] != null
                                                ? Text(cellText(rows[ri][i]).replaceAll('\n', ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: mono)
                                                : Text(
                                                    'NULL',
                                                    style: mono.copyWith(color: t.textSecondary, fontStyle: FontStyle.italic),
                                                  ),
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
                  ),
                ),
              ),
            ),
          ),
          if (pages > 1)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(tooltip: l.dbPrevPage, onPressed: _page > 0 ? () => setState(() => _page--) : null, icon: const Icon(LucideIcons.chevronLeft)),
                  Text(l.dbPageOf(_page + 1, pages), style: Theme.of(context).textTheme.bodyMedium),
                  IconButton(
                    tooltip: l.dbNextPage,
                    onPressed: _page < pages - 1 ? () => setState(() => _page++) : null,
                    icon: const Icon(LucideIcons.chevronRight),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The full text of a cell (cells are cut to one line in the table). Plain text (no system copy menu); "Copy" goes
/// through the sensitive clipboard (cleared after a while, hidden from the keyboard's clipboard preview).
Future<void> showCellSheet(BuildContext context, DbResultColumn col, Object? value) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) {
      final l = AppLocalizations.of(c);
      final tt = Theme.of(c).textTheme;
      final text = value == null ? 'NULL' : cellText(value);
      return DbSecure(
        child: SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(TiphysTokens.gutter, 0, TiphysTokens.gutter, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l.dbCellTitle, style: tt.bodySmall),
                  Text(col.name, style: tt.titleLarge?.copyWith(fontFamily: monoFamily, fontSize: 18)),
                  if (col.type != null && col.type!.isNotEmpty) Text(col.type!, style: tt.bodySmall),
                  const SizedBox(height: 12),
                  Text(
                    text,
                    style: TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.4, color: c.tokens.text),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton(onPressed: () => Navigator.pop(c), child: Text(l.commonClose)),
                      const Spacer(),
                      if (value != null)
                        Consumer(
                          builder: (c, ref, _) => OutlinedButton.icon(
                            onPressed: () async {
                              await ref.read(sensitiveClipboardProvider).copy(text);
                              if (c.mounted) toast(c, l.commonCopied);
                            },
                            icon: const Icon(LucideIcons.copy, size: 16),
                            label: Text(l.commonCopy),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Charts

List<Color> _palette(TiphysTokens t) => [
  t.accent,
  const Color(0xFF30B0C7),
  t.warning,
  const Color(0xFF8E6BD8),
  t.success,
  t.danger,
  const Color(0xFFE5795A),
  const Color(0xFF5E5CE6),
];

/// A saved query's result drawn per its chart config; falls back to the table (and says why) when the config doesn't fit.
class DbChartView extends StatelessWidget {
  const DbChartView({super.key, required this.result, required this.config});
  final DbResult result;
  final DbChartConfig config;

  static String _short(String s) => s.length > 10 ? '${s.substring(0, 9)}…' : s;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final data = ChartData.build(result, config);
    if (data.type == 'table') return DbResultView(result: result);
    return DbSecure(child: _chart(context, data, l, t, tt));
  }

  Widget _chart(BuildContext context, ChartData data, AppLocalizations l, TiphysTokens t, TextTheme tt) {
    if (!data.ok) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DbNote(switch (data.problem!) {
            ChartProblem.noRows => l.dbChartNoRows,
            ChartProblem.noNumeric => l.dbChartNoNumeric,
            ChartProblem.missingColumns => l.dbChartMissing,
          }),
          if (data.problem != ChartProblem.noRows) ...[const SizedBox(height: 12), DbResultView(result: result)],
        ],
      );
    }
    if (data.type == 'stat') {
      return TCard(
        child: Column(
          children: [
            Semantics(
              label: '${data.statLabel}: ${data.stat}',
              child: ExcludeSemantics(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    data.stat ?? '',
                    style: tt.displayMedium?.copyWith(color: t.accent, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(data.statLabel ?? '', style: tt.bodySmall),
          ],
        ),
      );
    }
    final colors = _palette(t);
    final n = data.labels.length;
    final allValues = [for (final s in data.series) ...s.values.whereType<double>()];
    final maxV = allValues.isEmpty ? 1.0 : allValues.reduce(math.max);
    final minV = allValues.isEmpty ? 0.0 : allValues.reduce(math.min);
    final lo = data.type == 'bar' ? math.min(0.0, minV) : minV;
    final labelEvery = math.max(1, (n / 4).ceil());
    final titles = FlTitlesData(
      topTitles: const AxisTitles(),
      rightTitles: const AxisTitles(),
      leftTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 42,
          getTitlesWidget: (v, m) =>
              v == m.max || v == m.min ? Text(_axisNum(v), style: TextStyle(fontSize: 10, color: t.textSecondary)) : const SizedBox.shrink(),
        ),
      ),
      bottomTitles: AxisTitles(
        sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 22,
          interval: 1,
          getTitlesWidget: (v, m) {
            final i = v.round();
            if (v != i.toDouble() || i < 0 || i >= n || i % labelEvery != 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_short(data.labels[i]), style: TextStyle(fontSize: 10, color: t.textSecondary)),
            );
          },
        ),
      ),
    );
    final grid = FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => FlLine(color: t.separator, strokeWidth: 1));
    final summary = '${result.queryName ?? ''} ${data.series.map((s) => s.name).join(', ')}';
    return TCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 220,
            child: Semantics(
              label: summary.trim(),
              child: ExcludeSemantics(
                child: data.type == 'line'
                    ? LineChart(
                        LineChartData(
                          minY: lo == maxV ? lo - 1 : lo,
                          maxY: lo == maxV ? maxV + 1 : maxV,
                          gridData: grid,
                          borderData: FlBorderData(show: false),
                          titlesData: titles,
                          lineTouchData: const LineTouchData(enabled: false),
                          lineBarsData: [
                            for (var k = 0; k < data.series.length; k++)
                              LineChartBarData(
                                spots: [
                                  for (var i = 0; i < n; i++)
                                    if (data.series[k].values[i] != null) FlSpot(i.toDouble(), data.series[k].values[i]!),
                                ],
                                color: colors[k % colors.length],
                                barWidth: 2.5,
                                isCurved: false,
                                dotData: FlDotData(show: n <= 12),
                              ),
                          ],
                        ),
                      )
                    : BarChart(
                        BarChartData(
                          minY: lo,
                          maxY: maxV <= lo ? lo + 1 : maxV,
                          gridData: grid,
                          borderData: FlBorderData(show: false),
                          titlesData: titles,
                          barTouchData: BarTouchData(enabled: false),
                          barGroups: [
                            for (var i = 0; i < n; i++)
                              BarChartGroupData(
                                x: i,
                                barsSpace: 2,
                                barRods: [
                                  for (var k = 0; k < data.series.length; k++)
                                    BarChartRodData(
                                      toY: data.series[k].values[i] ?? 0,
                                      color: colors[k % colors.length],
                                      width: math.max(4, math.min(22, 220 / (n * data.series.length + 1))),
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
          if (data.series.length > 1) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                for (var k = 0; k < data.series.length; k++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(color: colors[k % colors.length], shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(data.series[k].name, style: tt.bodySmall),
                    ],
                  ),
              ],
            ),
          ],
          if (result.rowCount > ChartData.maxPoints)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(l.dbChartFirstPoints(ChartData.maxPoints), style: tt.bodySmall),
            ),
        ],
      ),
    );
  }

  static String _axisNum(double v) =>
      v.abs() >= 1000 ? '${(v / 1000).toStringAsFixed(v.abs() >= 10000 ? 0 : 1)}k' : (v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1));
}
