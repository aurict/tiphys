// Home screen "Güvenlik" card (shield / rings / bars) and its style picker in Settings › Home screen.
// Machine names are examples (argo, atlas, orion).
// To update: TZ=Europe/Berlin flutter test test/goldens/security_home_card_test.dart --update-goldens
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/security/security_data.dart';
import 'package:tiphys/features/settings/general_settings.dart' show HomeCardsScreen;
import 'package:tiphys/features/security/security_home_card.dart';
import 'package:tiphys/features/security/security_screen.dart' show HomeSecurityCard;
import 'package:tiphys/state/providers.dart';
import 'package:tiphys/widgets/surfaces.dart';

import '../helpers/harness.dart';

Profile _profile({SecurityStyle style = SecurityStyle.shield, List<String>? cards}) {
  final j = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
  final home = j['app']['home'] as Map<String, dynamic>;
  home['cards'] = cards ?? ['security', 'infra', 'claude', 'system'];
  home['securityStyle'] = style.name;
  return codec.decode(jsonEncode(j)).toProfile();
}

Harness _env({SecurityStyle style = SecurityStyle.shield, bool feature = true, List<String>? cards, List<Override> extra = const []}) => Harness(
      profile: _profile(style: style, cards: cards),
      agentFeatures: [...Harness.defaultAgentFeatures, if (feature) 'security'],
      extra: [...extra],
    );

Future<void> _load(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true;
}

/// 1, 3 (fixture default: argo 91, orion 52, atlas 100) or 5 audited machines.
void _hosts(int n) {
  final st = FakeAgent.security;
  switch (n) {
    case 1:
      st.hosts['argo']!.removeWhere((h) => h.id == 'self');
      st.hosts['atlas']!.clear();
    case 5:
      st.hosts['atlas']!
        ..add(FakeSecHost('edge1', 'edge1', 'ssh', score: 70))
        ..add(FakeSecHost('edge2', 'edge2', 'ssh', score: null, lastOkAgo: null));
  }
}

String _uri(ProviderContainer c) {
  final cfg = c.router.routerDelegate.currentConfiguration;
  final m = cfg.last;
  return m is ImperativeRouteMatch ? m.matches.uri.toString() : cfg.uri.toString();
}

/// Text inside the Security card only (the infra card also lists the host names).
Finder _inCard(String text) => find.descendant(of: find.byType(SecurityHomeCard), matching: find.textContaining(text));

/// Saving the profile is real file I/O: wait (in real time) until [done].
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 20 && !done(); i++) {
    await _load(tester);
  }
}

/// Scrolls the settings page so [f] is in the middle (the pinned header would cover it at the very top).
Future<void> _bringToMiddle(WidgetTester tester, Finder f) async {
  final pos = tester.state<ScrollableState>(_settingsScroll).position;
  for (var i = 0; i < 3; i++) {
    pos.jumpTo((pos.pixels + tester.getCenter(f).dy - 400).clamp(0, pos.maxScrollExtent));
    await tester.pump();
  }
}

Rect _card(WidgetTester tester) => tester.getRect(find.byType(TCard).first);

Finder get _settingsScroll => find.descendant(of: find.byType(HomeCardsScreen), matching: find.byType(Scrollable)).first;

void main() {
  setUp(() {
    FakeAgent.resetSecurity();
    FakeAgent.calls.clear();
  });

  group('birim', () {
    test('puan bandı ve bant sözcüğü', () {
      expect(securityBand(85), SecurityBand.good);
      expect(securityBand(84), SecurityBand.warn);
      expect(securityBand(60), SecurityBand.warn);
      expect(securityBand(59), SecurityBand.bad);
      expect(securityBand(null), SecurityBand.none);
    });

    test('en kötüden iyiye sıralama, puansız en sonda', () {
      final h = [
        for (final (id, s) in [('a', 91), ('b', null), ('c', 52), ('d', 100)])
          SecurityHostSummary(Host(id: 'x', name: 'x', address: 'x'), {'id': id, 'name': id, 'role': 'server', 'source': 'local', 'score': s, 'counts': {}}),
      ];
      expect(sortedByRisk(h).map((e) => e.id), ['c', 'a', 'd', 'b']);
    });
  });

  group('ayarlar › ana ekran', () {
    testWidgets('kart açılınca stil seçici görünür, seçim profile kaydedilir', (tester) async {
      final c = await _env(cards: ['infra', 'claude']).pump(tester, route: '/settings/home');
      await _load(tester);
      expect(find.text(upper('Güvenlik kartı stili', 'tr')), findsNothing, reason: 'kart kapalıyken seçici yok');
      final sw = find.descendant(of: find.widgetWithText(ListTile, 'Güvenlik'), matching: find.byType(Switch));
      await _bringToMiddle(tester, sw);
      await tester.tap(sw);
      await _until(tester, () => c.read(profileProvider).app.cards.contains('security'));
      expect(c.read(profileProvider).app.cards, contains('security'));
      expect(find.text(upper('Güvenlik kartı stili', 'tr')), findsOneWidget);
      for (final s in ['Kalkan', 'Halkalar', 'Çubuklar']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(c.read(profileProvider).app.securityStyle, SecurityStyle.shield);
      await _bringToMiddle(tester, find.text('Çubuklar'));
      await tester.tap(find.text('Çubuklar'));
      await _until(tester, () => c.read(profileProvider).app.securityStyle == SecurityStyle.bars);
      expect(c.read(profileProvider).app.securityStyle, SecurityStyle.bars);
      final sel = find.bySemanticsLabel(RegExp('^Çubuklar,'));
      expect(tester.getSemantics(sel), isSemantics(isSelected: true, isInMutuallyExclusiveGroup: true));
      expect(tester.getSemantics(find.bySemanticsLabel(RegExp('^Kalkan,'))), isSemantics(isSelected: false));
      for (final s in ['Kalkan', 'Halkalar', 'Çubuklar']) {
        expect(tester.getSize(find.ancestor(of: find.text(s), matching: find.byType(InkWell)).first).height, greaterThanOrEqualTo(44));
      }
      await _finish(tester);
    });

    testWidgets('stil seçici görünümü (TR, açık)', (tester) async {
      await _env(cards: ['infra', 'claude', 'security'], style: SecurityStyle.rings).pump(tester, route: '/settings/home');
      await _load(tester);
      await tester.scrollUntilVisible(find.text('Çubuklar'), 150, scrollable: _settingsScroll);
      await _load(tester);
      expect(tester.takeException(), isNull);
      await golden('png/home_settings_security_style_light_tr.png');
      await _finish(tester);
    });
  });

  for (final style in SecurityStyle.values) {
    group('kart ${style.name}', () {
      for (final dark in [false, true]) {
        testWidgets('3 makine ${dark ? 'koyu' : 'açık'} TR', (tester) async {
          await _env(style: style).pump(tester, dark: dark);
          await _load(tester);
          expect(tester.takeException(), isNull);
          expect(find.text('Güvenlik'), findsWidgets);
          expect(find.textContaining('orion'), findsWidgets);
          expect(find.textContaining('52'), findsWidgets);
          expect(find.textContaining('Zayıf'), findsWidgets);
          expect(find.textContaining('İyi'), findsWidgets);
          await golden('png/home_security_${style.name}_${dark ? 'dark' : 'light'}_tr.png');
          await _finish(tester);
        });
      }

      for (final n in [1, 5]) {
        testWidgets('$n makine', (tester) async {
          _hosts(n);
          await _env(style: style).pump(tester);
          await _load(tester);
          expect(tester.takeException(), isNull);
          final labels = find.bySemanticsLabel(RegExp(r'Güvenlik puanı|Puan yok'));
          if (n == 1) {
            expect(_inCard('orion'), findsWidgets);
            expect(_inCard('argo'), findsNothing, reason: 'tek makine');
            expect(_inCard('atlas'), findsNothing);
          } else {
            expect(_inCard('orion'), findsWidgets);
            switch (style) {
              case SecurityStyle.shield:
                expect(_inCard('edge1'), findsWidgets);
                expect(_inCard('+3'), findsOneWidget, reason: '2 makine + "+N"');
              case SecurityStyle.rings:
                expect(_inCard('+2'), findsOneWidget, reason: 'ilk 3 + "+N"');
                expect(_inCard('edge2'), findsNothing);
              case SecurityStyle.bars:
                expect(_inCard('edge2'), findsWidgets);
                expect(_inCard('+'), findsNothing);
            }
            expect(labels, findsWidgets);
          }
          await _finish(tester);
        });
      }

      testWidgets('durumlar: kurulu değil, yükleniyor, hata ve tekrar dene, bayat', (tester) async {
        // No agent with the feature: short empty state inside the card.
        await _env(style: style, feature: false).pump(tester);
        await _load(tester);
        expect(find.text('Güvenlik merkezi kurulu değil'), findsOneWidget);
        expect(find.textContaining('features.security'), findsOneWidget);
        await _finish(tester);
      });

      testWidgets('yükleniyor iskeleti aynı yükseklikte', (tester) async {
        if (style == SecurityStyle.bars) return; // the list height follows the number of machines
        await _env(style: style).pump(tester);
        await _load(tester);
        final loaded = _card(tester).height;
        await _finish(tester);

        final never = Completer<SecurityFeed>();
        await _env(style: style, extra: [securityFeedProvider.overrideWith((ref) => never.future)]).pump(tester);
        await _load(tester);
        expect(find.text('Güvenlik merkezi kurulu değil'), findsNothing);
        expect(_inCard('orion'), findsNothing);
        expect(_card(tester).height, closeTo(loaded, 0.5), reason: 'yerleşim kayması olmamalı');
        await _finish(tester);
      });

      testWidgets('hata → tekrar dene', (tester) async {
        FakeAgent.security.overviewErrors['argo'] = const AgentError('net.unreachable');
        FakeAgent.security.overviewErrors['atlas'] = const AgentError('net.unreachable');
        await _env(style: style).pump(tester);
        await _load(tester);
        expect(find.text('Güvenlik verisi alınamadı'), findsOneWidget);
        FakeAgent.security.overviewErrors.clear();
        await tester.tap(find.text('Tekrar dene'));
        await _load(tester);
        expect(find.text('Güvenlik verisi alınamadı'), findsNothing);
        expect(find.textContaining('orion'), findsWidgets);
        await _finish(tester);
      });

      testWidgets('bayat veri: son bilinen durum', (tester) async {
        final o = FakeAgent.security.find('argo', 'orion')!;
        o.stale = true;
        o.lastOkAgo = const Duration(hours: 7);
        await _env(style: style).pump(tester);
        await _load(tester);
        expect(find.textContaining('Son bilinen durum'), findsWidgets);
        if (style != SecurityStyle.shield) expect(find.textContaining('son bilinen'), findsWidgets);
        expect(find.bySemanticsLabel(RegExp(r'orion.*Son bilinen durum')), findsOneWidget);
        await _finish(tester);
      });

      testWidgets('dokunma: kart /security, makine kendi ekranına', (tester) async {
        final c = await _env(style: style).pump(tester);
        await _load(tester);
        await tester.tap(find.text('Güvenlik').first);
        await _load(tester);
        expect(_uri(c), '/security');
        c.router.go('/');
        await _load(tester);
        await tester.tap(find.bySemanticsLabel(RegExp(r'^orion,')));
        await _load(tester);
        expect(_uri(c), '/security/orion?host=argo');
        await _finish(tester);
      });

      testWidgets('375 px, metin ×2.0: taşma yok', (tester) async {
        _hosts(5);
        await _env(style: style).pump(tester);
        tester.view.physicalSize = const Size(375 * 2, 812 * 2);
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        await _load(tester);
        expect(tester.takeException(), isNull);
        final r = _card(tester);
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(375));
        await _finish(tester);
      });

      testWidgets('animasyonlar açıkken ilk açılışta dolar (taşma yok)', (tester) async {
        await _env(style: style).pump(tester);
        tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures();
        await tester.pumpWidget(const SizedBox());
        await _env(style: style).pump(tester);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
        await _finish(tester);
      });
    });
  }

  testWidgets('375 px, metin ×1.6 kalkan görüntüsü (TR, açık)', (tester) async {
    _hosts(5);
    await _env().pump(tester);
    tester.view.physicalSize = const Size(375 * 2, 812 * 2);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    await _load(tester);
    expect(tester.takeException(), isNull);
    await golden('png/home_security_shield_375_large_text_light_tr.png');
    await _finish(tester);
  });

  group('dikkat satırı', () {
    testWidgets('kart açıkken küçük satır yok (çift gösterim yok)', (tester) async {
      await _env().pump(tester);
      await _load(tester);
      expect(find.byType(HomeSecurityCard), findsNothing);
      expect(find.text('2 değişiklik · 1 kritik bulgu'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('kart kapalıyken satır eskisi gibi', (tester) async {
      await _env(cards: ['infra', 'claude', 'system']).pump(tester);
      await _load(tester);
      expect(find.byType(HomeSecurityCard), findsOneWidget);
      expect(find.text('2 değişiklik · 1 kritik bulgu'), findsOneWidget);
      expect(find.byType(SecurityHomeCard), findsNothing);
      await _finish(tester);
    });

    testWidgets('grid düzeninde de bölümlerde tam genişlikli kart', (tester) async {
      final j = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
      j['app']['home']['cards'] = ['security', 'infra'];
      j['app']['home']['layout'] = 'grid';
      await Harness(profile: codec.decode(jsonEncode(j)).toProfile(), agentFeatures: [...Harness.defaultAgentFeatures, 'security']).pump(tester);
      await _load(tester);
      expect(find.byType(SecurityHomeCard), findsOneWidget);
      expect(find.byType(HomeSecurityCard), findsNothing);
      await _finish(tester);
    });
  });
}
