// 7. faz ekranları: araçlar (süreçler, portlar, pano, işlem kaydı), git, Grafana alarmları, bakım pencereleri,
// "bilgisayara gönder". Güncellemek için: flutter test test/goldens/phase7_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:tiphys/features/git/git_screen.dart';
import 'package:tiphys/features/monitoring/grafana_alerts_screen.dart';
import 'package:tiphys/features/monitoring/grafana_screen.dart';
import 'package:tiphys/features/monitoring/maintenance_screen.dart';
import 'package:tiphys/features/system/tools.dart';
import 'package:tiphys/state/providers.dart';

import '../helpers/harness.dart';

Future<void> _open(WidgetTester tester, ProviderContainer c, Widget page) async {
  c.router.routerDelegate.navigatorKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
}

void main() {
  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('sistem araçları $v', (tester) async {
      await Harness().pump(tester, route: '/system', dark: dark);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
      await tester.drag(find.byType(ListView).first, const Offset(0, -620));
      await settle(tester);
      expect(find.text('Süreçler'), findsOneWidget);
      await golden('png/p7_system_tools_${v}_tr.png');
      await _finish(tester);
    });

    testWidgets('git $v', (tester) async {
      await Harness().pump(tester, route: '/git?host=argo&path=/home/user/Desktop/tiphys', dark: dark);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
      await golden('png/p7_git_${v}_tr.png');
      await _finish(tester);
    });

    testWidgets('süreçler $v', (tester) async {
      final c = await Harness().pump(tester, dark: dark);
      await _open(tester, c, ProcessesScreen(host: c.read(profileProvider).host('argo')!));
      await golden('png/p7_processes_${v}_tr.png');
      await _finish(tester);
    });

    testWidgets('grafana alarmları $v', (tester) async {
      final c = await Harness().pump(tester, dark: dark);
      await _open(tester, c, GrafanaAlertsScreen(config: c.read(profileProvider).integrations.grafana.first));
      await tester.tap(find.text('Tüm kurallar'));
      await settle(tester);
      await golden('png/p7_grafana_alerts_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('grafana hızlı sorgu', (tester) async {
    final c = await Harness().pump(tester, dark: true);
    await _open(tester, c, GrafanaExploreScreen(config: c.read(profileProvider).integrations.grafana.first));
    await tester.enterText(find.byType(TextField).first, 'rate(node_cpu_seconds_total{mode!="idle"}[5m])');
    await tester.tap(find.text('Çalıştır'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    await golden('png/p7_grafana_explore_dark_tr.png');
    await _finish(tester);
  });

  testWidgets('git geçmiş', (tester) async {
    await Harness().pump(tester, route: '/git?host=argo&path=/home/user/Desktop/tiphys');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    await tester.tap(find.text('Geçmiş'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    await golden('png/p7_git_history_light_tr.png');
    await _finish(tester);
  });

  testWidgets('git diff koyu', (tester) async {
    final c = await Harness().pump(tester, dark: true);
    await _open(tester, c, const GitDiffScreen(hostId: 'argo', path: '/home/user/Desktop/tiphys', file: 'PLAN.md', title: 'PLAN.md'));
    await golden('png/p7_git_diff_dark_tr.png');
    await _finish(tester);
  });

  testWidgets('portlar', (tester) async {
    final c = await Harness().pump(tester);
    await _open(tester, c, PortsScreen(host: c.read(profileProvider).host('argo')!));
    await golden('png/p7_ports_light_tr.png');
    await _finish(tester);
  });

  testWidgets('pano ve işlem kaydı', (tester) async {
    final c = await Harness().pump(tester, dark: true);
    final host = c.read(profileProvider).host('argo')!;
    await _open(tester, c, ClipboardScreen(host: host));
    await golden('png/p7_clipboard_dark_tr.png');
    await _open(tester, c, AuditScreen(host: host));
    await golden('png/p7_audit_dark_tr.png');
    await _finish(tester);
  });

  testWidgets('bakım pencereleri', (tester) async {
    final c = await Harness().pump(tester);
    await _open(tester, c, const MaintenanceScreen());
    await golden('png/p7_maintenance_light_tr.png');
    await _finish(tester);
  });

  testWidgets('bilgisayara gönder (en)', (tester) async {
    final c = await Harness().pump(tester, lang: 'en');
    c.router.push('/share', extra: [
      SharedMediaFile(path: 'https://example.com/makale', type: SharedMediaType.url),
      SharedMediaFile(path: '/nonexistent/IMG_2041.jpg', type: SharedMediaType.image, mimeType: 'image/jpeg'),
    ]);
    await settle(tester);
    await golden('png/p7_share_light_en.png');
    await _finish(tester);
  });
}
