// 9.7 quick note to Obsidian, 9.8 media remote, 9.9 "open on PC".
// To update: flutter test test/goldens/notes_media_test.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/claude/chat_markdown.dart';
import 'package:tiphys/features/notes/obsidian.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/state/providers.dart';
import 'package:tiphys/theme/theme.dart';
import 'package:tiphys/theme/tokens.dart';

import '../helpers/harness.dart';

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 30));
}

Future<void> _wait(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await settle(tester);
}

/// POST/PUT requests sent to the agent (method, path, body) in a comparable form.
List<String> _sent() => [for (final c in FakeAgent.calls.where((c) => c.$1 != 'GET')) '${c.$1} ${c.$2} ${c.$3}'];

Profile _withObsidian({List<String>? cards}) {
  final p = exampleProfile();
  return p.copyWith(
    integrations: p.integrations.copyWith(obsidian: () => const ObsidianConfig(vault: 'Notlar', folder: 'Gelen kutusu')),
    app: cards == null ? null : p.app.copyWith(cards: cards),
  );
}

/// Captures obsidian:// links; if [ok] is false, behaves as if "Obsidian is not installed".
(List<Uri>, Override) _launcher({bool ok = true}) {
  final launched = <Uri>[];
  return (launched, obsidianLauncherProvider.overrideWithValue((u) async {
    launched.add(u);
    return ok;
  }));
}

void main() {
  setUp(() {
    FakeAgent.calls.clear();
    FakeAgent.media = sampleMedia();
  });

  for (final dark in [false, true]) {
    final v = dark ? 'dark' : 'light';
    testWidgets('medya kumandası $v', (tester) async {
      await Harness().pump(tester, route: '/system/media?host=argo', dark: dark);
      await _wait(tester);
      expect(find.text('Kaç Kadeh Kırıldı'), findsOneWidget);
      expect(find.text('Sezen Aksu · Gülümse'), findsOneWidget);
      expect(find.text('1:01'), findsOneWidget);
      expect(find.text('4:05'), findsOneWidget);
      expect(find.text('Firefox'), findsOneWidget); // multiple players: picker
      expect(find.text('%60'), findsOneWidget);
      await golden('png/media_${v}_tr.png');
      await _finish(tester);
    });
  }

  testWidgets('medya: düğmeler oynatıcıya, ses kaydırıcısı ve sessiz ajana gider', (tester) async {
    await Harness().pump(tester, route: '/system/media?host=argo');
    await _wait(tester);
    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await _wait(tester);
    }

    await tap(find.byIcon(LucideIcons.pause));
    await tap(find.byTooltip('Sonraki'));
    await tap(find.byTooltip('10 sn geri'));
    await tap(find.byTooltip('Sesi kapat'));
    expect(_sent(), [
      'POST /v1/media/play-pause {player: spotify}',
      'POST /v1/media/next {player: spotify}',
      'POST /v1/media/seek {player: spotify, seconds: -10.0}',
      'PUT /v1/media/volume {muted: true}',
    ]);
    // Player picker: once Firefox is selected, the status is queried for that player.
    await tap(find.text('Firefox'));
    expect(FakeAgent.calls.where((c) => c.$2 == '/v1/media').last.$3, {'player': 'firefox.instance_1_42'});
    // The volume slider carries a semantic value.
    expect(tester.widget<Slider>(find.byType(Slider).last).semanticFormatterCallback!(60), 'Ses düzeyi %60');
    expect(tester.widget<Slider>(find.byType(Slider).first).semanticFormatterCallback!(61.5), '1:01 / 4:05');
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('medya: çalan yoksa boş durum, ses yine ayarlanabilir', (tester) async {
    FakeAgent.media = {
      'state': {'players': [], 'player': null},
      'volume': {'percent': 35, 'muted': true},
    };
    await Harness().pump(tester, route: '/system/media?host=argo');
    await _wait(tester);
    expect(find.text("PC'de çalan bir şey yok"), findsOneWidget);
    expect(find.byTooltip('Sesi aç'), findsOneWidget);
    expect(find.text('Kapalı'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('ana ekran: "Şimdi çalıyor" kartı ve hızlı not kısayolu', (tester) async {
    await Harness(profile: _withObsidian(cards: ['infra', 'nowPlaying', 'claude', 'system', 'quickAccess'])).pump(tester);
    await _wait(tester);
    expect(find.text('Şimdi çalıyor · Spotify'), findsOneWidget);
    await golden('png/home_now_playing_light_tr.png');
    await tester.tap(find.byTooltip('Duraklat'));
    await _wait(tester);
    expect(_sent(), ['POST /v1/media/play-pause {player: spotify}']);
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await settle(tester);
    await tester.tap(find.text('Hızlı not'));
    await settle(tester);
    expect(find.text("Obsidian'a kaydet"), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('ana ekran: bir şey çalmıyorsa kart görünmez', (tester) async {
    FakeAgent.media = {
      'state': {'players': [], 'player': null},
      'volume': {'percent': 35, 'muted': false},
    };
    await Harness(profile: _withObsidian(cards: ['nowPlaying', 'infra'])).pump(tester);
    await _wait(tester);
    expect(find.textContaining('Şimdi çalıyor'), findsNothing);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('hızlı not: obsidian:// bağlantısı kurulur, kaydedince kapanır', (tester) async {
    final (launched, override) = _launcher();
    final c = await Harness(profile: _withObsidian(), extra: [override]).pump(tester);
    c.router.push('/note', extra: const QuickNoteArgs(text: 'Yedek diski değiştir\nCumartesi, 2 TB', title: 'Ev işleri'));
    await settle(tester);
    expect(find.text('Notlar › Gelen kutusu/Ev işleri.md'), findsOneWidget);
    await golden('png/quick_note_light_tr.png');
    // Switch to daily note: the title field is hidden, the target becomes the daily note.
    await tester.tap(find.text('Günlük nota ekle'));
    await settle(tester);
    expect(find.text('Notlar › Günlük/2026-11-14.md'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, "Obsidian'a kaydet"));
    await settle(tester);
    expect(launched, hasLength(1));
    final q = Uri.splitQueryString(launched.single.query);
    expect(launched.single.toString(), startsWith('obsidian://new?vault=Notlar&file=G%C3%BCnl%C3%BCk%2F2026-11-14&content='));
    expect(q, {'vault': 'Notlar', 'file': 'Günlük/2026-11-14', 'content': 'Yedek diski değiştir\nCumartesi, 2 TB', 'append': 'true', 'silent': 'true'});
    expect(find.text("Obsidian'a gönderildi"), findsOneWidget);
    expect(find.text('Notlar › Günlük/2026-11-14.md'), findsNothing); // screen closed
    await _finish(tester);
  });

  testWidgets('hızlı not: Obsidian yüklü değilse açık mesaj', (tester) async {
    final (launched, override) = _launcher(ok: false);
    final c = await Harness(profile: _withObsidian(), extra: [override]).pump(tester);
    c.router.push('/note', extra: const QuickNoteArgs(text: 'deneme'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, "Obsidian'a kaydet"));
    await settle(tester);
    expect(launched, hasLength(1));
    expect(find.textContaining('Obsidian uygulaması yüklü mü?'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets('hızlı not: kasa ayarlı değilse ayara yönlendirir, kaydet kapalı', (tester) async {
    final (launched, override) = _launcher();
    final c = await Harness(extra: [override]).pump(tester);
    c.router.push('/note');
    await settle(tester);
    expect(find.text("Önce Obsidian'ı ayarla"), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, "Obsidian'a kaydet")).onPressed, isNull);
    await tester.tap(find.text('Obsidian ayarları'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'Kasa adı'), 'Notlar');
    await tester.tap(find.text('Kaydet'));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await settle(tester);
    expect(c.read(profileProvider).integrations.obsidian?.vault, 'Notlar');
    expect(c.read(profileProvider).integrations.obsidian?.folder, 'Gelen kutusu');
    expect(find.text('Notlar › Gelen kutusu/Not 2026-11-14 14.05.md'), findsOneWidget);
    expect(launched, isEmpty);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets("Claude cevabı: seçim menüsünde Obsidian'a kaydet tüm cevabı verir", (tester) async {
    String? saved;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(TiphysTokens.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('tr'),
      home: Scaffold(body: ChatMarkdown('İlk paragraf.\n\nİkinci paragraf.', onSaveNote: () => saved = 'tümü')),
    ));
    await tester.longPress(find.textContaining('İkinci paragraf', findRichText: true));
    await settle(tester);
    await tester.tap(find.text("Obsidian'a kaydet"));
    await settle(tester);
    expect(saved, 'tümü');
    debugDisableShadows = true;
  });

  testWidgets("paylaşılan bağlantı: PC'de aç ajana gider", (tester) async {
    final c = await Harness().pump(tester);
    c.router.push('/share', extra: [SharedMediaFile(path: 'Şuna bak https://example.com/makale?id=7.', type: SharedMediaType.text)]);
    await settle(tester);
    expect(find.text('https://example.com/makale?id=7'), findsOneWidget);
    await tester.tap(find.text('argo (PC) üzerinde aç'));
    await _wait(tester);
    expect(_sent(), ['POST /v1/desktop/open {url: https://example.com/makale?id=7}']);
    expect(find.text('argo (PC) üzerinde açıldı'), findsOneWidget);
    await _finish(tester);
    debugDisableShadows = true;
  });

  testWidgets("Sistem › panodaki bağlantıyı PC'de aç (onaylı)", (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'link: https://github.com/aurict/tiphys/pull/12'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await Harness().pump(tester, route: '/system');
    await _wait(tester);
    await tester.scrollUntilVisible(find.text("PC'de aç").hitTestable(), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text("PC'de aç"));
    await settle(tester);
    expect(find.textContaining('https://github.com/aurict/tiphys/pull/12'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, "PC'de aç"));
    await _wait(tester);
    expect(_sent(), ['POST /v1/desktop/open {url: https://github.com/aurict/tiphys/pull/12}']);
    await _finish(tester);
    debugDisableShadows = true;
  });
}
