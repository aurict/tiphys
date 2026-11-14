// Ekran görüntüleri: her ekran açık/koyu × TR/EN, 390×844 (2x). Güncellemek için:
//   flutter test test/goldens --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/app.dart';
import 'package:tiphys/core/profile/model.dart';

import '../helpers/harness.dart';

void main() {
  const variants = [('light', false, 'tr'), ('dark', true, 'tr'), ('light', false, 'en'), ('dark', true, 'en')];

  for (final (theme, dark, lang) in variants) {
    testWidgets('ana ekran $theme $lang', (tester) async {
      await Harness().pump(tester, dark: dark, lang: lang);
      await golden('png/home_${theme}_$lang.png');
    });
  }

  testWidgets('ana ekran boş profil', (tester) async {
    await Harness(profile: Profile.empty).pump(tester);
    await golden('png/home_empty_light_tr.png');
  });

  for (final (theme, dark, lang) in [variants[0], variants[3]]) {
    testWidgets('ayarlar $theme $lang', (tester) async {
      await Harness().pump(tester, route: '/settings', dark: dark, lang: lang);
      await golden('png/settings_${theme}_$lang.png');
    });
  }

  for (final (name, route) in [
    ('host_edit', '/settings/hosts/edit?id=argo'),
    ('integrations', '/settings/integrations'),
    ('secrets', '/settings/secrets'),
    ('profile', '/settings/profile'),
    ('security', '/settings/security'),
  ]) {
    testWidgets('$name koyu tr', (tester) async {
      await Harness().pump(tester, route: route, dark: true);
      await settle(tester);
      await golden('png/${name}_dark_tr.png');
    });
  }

  for (final (name, route, dark) in [
    ('system_light_tr', '/system', false),
    ('system_dark_tr', '/system', true),
    ('terminal_dark_tr', '/terminal', true),
    ('files_light_tr', '/files', false),
    ('claude_light_tr', '/claude', false),
    ('sites_light_tr', '/monitor/sites', false),
    ('homepage_dark_tr', '/monitor/homepage', true),
    ('dozzle_dark_tr', '/monitor/dozzle', true),
    ('grafana_dark_tr', '/monitor/grafana', true),
    ('grafana_light_tr', '/monitor/grafana', false),
    ('claude_chat_dark_tr', '/claude/session/a1', true),
    ('claude_chat_light_tr', '/claude/session/a1', false),
    ('claude_markdown_light_tr', '/claude/session/md1', false),
    ('claude_markdown_dark_tr', '/claude/session/md1', true),
  ]) {
    testWidgets(name, (tester) async {
      await Harness().pump(tester, route: route, dark: dark);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
      await golden('png/$name.png');
      // Otomatik yenileme zamanlayıcıları test bitmeden temizlensin.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    });
  }

  testWidgets('terminal oturumu salt okunur açılır ve telefona devralınır', (tester) async {
    FakeAgent.calls.clear();
    const id = '5e55a0c1-0000-4000-8000-000000000003';
    final container = await Harness().pump(tester, route: '/claude/history/$id?terminal=1&cwd=%2Fhome%2Fuser');
    await settle(tester);
    expect(find.text('Devam et'), findsNothing); // terminalde açık oturum buradan sürdürülmez
    await golden('png/claude_terminal_readonly_light_tr.png');
    await tester.tap(find.text('Telefona devral'));
    await settle(tester);
    await tester.tap(find.text('Telefona devral').last); // onay penceresindeki düğme
    await settle(tester);
    final post = FakeAgent.calls.lastWhere((c) => c.$1 == 'POST');
    expect(post.$2, '/v1/claude/terminal/$id/takeover');
    expect((post.$3 as Map)['confirm'], true);
    expect(container.read(routerProvider).routerDelegate.currentConfiguration.last.matchedLocation, '/claude/session/md1');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('uzun sohbet en son mesajdan açılır', (tester) async {
    await Harness().pump(tester, route: '/claude/session/long1');
    await settle(tester);
    expect(find.text('Mesaj 59'), findsOneWidget);
    expect(find.text('Mesaj 0'), findsNothing);
    debugDisableShadows = true; // harness değiştirdi; ekran görüntüsü almayan test kendisi geri alır
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('yeni Claude oturumu: ilk mesaj olmadan başlar, buton alt barın üstünde', (tester) async {
    FakeAgent.calls.clear();
    final container = await Harness().pump(tester, route: '/claude');
    await tester.tap(find.byTooltip('Yeni Claude oturumu'));
    await settle(tester);
    await golden('png/claude_new_session_light_tr.png');
    // Alt sekme barı sayfanın üstünde olsaydı dokunuş butona ulaşmazdı.
    await tester.tap(find.text('Başlat'));
    await settle(tester);
    final post = FakeAgent.calls.lastWhere((c) => c.$1 == 'POST' && c.$2 == '/v1/claude/sessions');
    expect((post.$3 as Map)['prompt'], '');
    expect(container.read(routerProvider).routerDelegate.currentConfiguration.last.matchedLocation, '/claude/session/md1');
    expect(find.text('Durum raporu'), findsWidgets); // sohbet ekranı açıldı
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });

  for (final dark in [false, true]) {
    testWidgets('grafana yeni paneller ${dark ? 'koyu' : 'açık'}', (tester) async {
      await Harness().pump(tester, route: '/monitor/grafana', dark: dark);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await settle(tester);
      await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -1400));
      await settle(tester);
      await golden('png/grafana_home_panels_${dark ? 'dark' : 'light'}_tr.png');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
    });
  }

  testWidgets('kilit ekranı', (tester) async {
    await Harness(pin: '123456').pump(tester);
    await golden('png/lock_light_tr.png');
  });

  testWidgets('ayarlar butonu ayarları açar', (tester) async {
    await Harness().pump(tester);
    await tester.tap(find.byTooltip('Ayarlar'));
    await settle(tester);
    expect(find.text('Hostlar'), findsOneWidget);
    debugDisableShadows = true;
  });
}
