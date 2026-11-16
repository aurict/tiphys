// Home screen layouts (Cards / Shortcuts / Focus) and the layout + shortcut settings in Settings › Home screen.
// To update: flutter test test/goldens/home_layouts_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/home/home_screen.dart';
import 'package:tiphys/features/home/shortcuts.dart';
import 'package:tiphys/features/settings/general_settings.dart';
import 'package:tiphys/features/system/events.dart';
import 'package:tiphys/state/providers.dart';
import 'package:tiphys/widgets/floating_tab_bar.dart';
import 'package:tiphys/theme/tokens.dart';

import '../helpers/harness.dart';

/// Example profile + Obsidian; [edit] modifies the JSON (long names etc.).
Profile _profile({required String layout, List<String>? shortcuts, List<String>? cards, void Function(Map<String, dynamic>)? edit}) {
  final j = jsonDecode(File('assets/profile/example.json').readAsStringSync()) as Map<String, dynamic>;
  final home = j['app']['home'] as Map<String, dynamic>;
  home['layout'] = layout;
  if (shortcuts != null) home['shortcuts'] = shortcuts;
  if (cards != null) home['cards'] = cards;
  j['integrations']['obsidian'] = {'vault': 'Notlar', 'folder': 'Gelen kutusu'};
  edit?.call(j);
  return codec.decode(jsonEncode(j)).toProfile();
}

/// Long host and integration names; all cards and all shortcuts enabled.
Profile _stress(String layout) => _profile(
      layout: layout,
      shortcuts: allShortcuts,
      cards: allHomeCards,
      edit: (j) {
        for (final h in (j['hosts'] as List).cast<Map<String, dynamic>>()) {
          h['name'] = '${h['id']}-çok-uzun-bir-sunucu-adı-ev-laboratuvarı (PC)';
        }
        (j['integrations']['grafana'] as List).first['name'] = 'Grafana · ev laboratuvarı izleme panosu uzun ad';
      },
    );

const _goldenShortcuts = ['vault', 'quickNote', 'media', 'events', 'compose', 'logs', 'newClaude', 'wake', 'dozzle'];

/// Saving the profile is several consecutive file operations: each finishes in real time, the rest is pumped in
/// fake time.
Future<void> _load(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await settle(tester);
}

/// Auto-refresh timers should be closed at the end of the test.
Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
  debugDisableShadows = true;
}

Future<void> _scrollTo(WidgetTester tester, String text) =>
    tester.scrollUntilVisible(find.text(text), 150, scrollable: _settingsScroll);

Finder get _settingsScroll => find.descendant(of: find.byType(HomeCardsScreen), matching: find.byType(Scrollable)).first;

Finder get _shortcutWidgets => find.byWidgetPredicate((w) => w is ShortcutTile || w is ShortcutRow);

void main() {
  for (final (name, layout) in [('grid', 'grid'), ('focus', 'focus')]) {
    for (final dark in [false, true]) {
      testWidgets('ana ekran $name ${dark ? 'koyu' : 'açık'}', (tester) async {
        await Harness(profile: _profile(layout: layout, shortcuts: _goldenShortcuts)).pump(tester, dark: dark);
        await _load(tester);
        expect(tester.takeException(), isNull);
        await golden('png/home_${name}_${dark ? 'dark' : 'light'}_tr.png');
        await _finish(tester);
      });
    }
  }

  testWidgets('ana ekran grid dar (320)', (tester) async {
    await Harness(profile: _profile(layout: 'grid', shortcuts: _goldenShortcuts)).pump(tester);
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    await _load(tester);
    expect(tester.takeException(), isNull);
    await golden('png/home_grid_narrow_light_tr.png');
    await _finish(tester);
  });

  testWidgets('ayarlar › ana ekran: düzen seçici', (tester) async {
    await Harness(profile: _profile(layout: 'cards')).pump(tester, route: '/settings/home');
    await _load(tester);
    expect(tester.takeException(), isNull);
    await golden('png/home_settings_layout_light_tr.png');
  });

  // Bounds: every layout × two sizes × light/dark × two text scales; all shortcuts, long names.
  for (final layout in ['cards', 'grid', 'focus']) {
    for (final size in const [Size(390, 844), Size(320, 640)]) {
      for (final dark in [false, true]) {
        for (final scale in [1.0, 1.3]) {
          testWidgets('sınırlar $layout ${size.width.toInt()}×${size.height.toInt()} ${dark ? 'koyu' : 'açık'} ×$scale', (tester) async {
            await Harness(profile: _stress(layout)).pump(tester, dark: dark);
            tester.view.physicalSize = size * 2;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await _load(tester);
            expect(tester.takeException(), isNull);

            final w = size.width;
            final scroll = find.descendant(of: find.byType(HomeScreen), matching: find.byType(Scrollable)).first;
            final pos = tester.state<ScrollableState>(scroll).position;
            final barTop = tester.getRect(find.byType(FloatingTabBar)).top;
            // Top to bottom in half-screen steps: every built shortcut stays within the content width.
            var seen = 0;
            for (var y = 0.0;; y += size.height / 2) {
              pos.jumpTo(y.clamp(0, pos.maxScrollExtent));
              await tester.pump();
              expect(tester.takeException(), isNull);
              for (var i = 0; i < _shortcutWidgets.evaluate().length; i++) {
                final r = tester.getRect(_shortcutWidgets.at(i));
                expect(r.left, greaterThanOrEqualTo(TiphysTokens.gutter - 0.01));
                expect(r.right, lessThanOrEqualTo(w - TiphysTokens.gutter + 0.01));
                seen++;
              }
              if (y >= pos.maxScrollExtent) break;
            }
            expect(seen, greaterThan(0));

            // When scrolled to the end, the end of the content (and the visible shortcuts) must stay above the floating
            // bar.
            await settle(tester);
            pos.jumpTo(pos.maxScrollExtent);
            await tester.pump();
            final list = tester.widget<ListView>(find.descendant(of: find.byType(HomeScreen), matching: find.byType(ListView)).first);
            final last = (list.childrenDelegate as SliverChildListDelegate).children.last;
            expect(tester.getRect(find.byWidget(last)).bottom, lessThanOrEqualTo(barTop));
            for (var i = 0; i < _shortcutWidgets.evaluate().length; i++) {
              final r = tester.getRect(_shortcutWidgets.at(i));
              if (r.top < size.height && r.bottom > 0) expect(r.bottom, lessThanOrEqualTo(barTop));
            }
            await _finish(tester);
          });
        }
      }
    }
  }

  testWidgets('düzen seçimi profile kaydedilir ve ana ekran değişir', (tester) async {
    final h = Harness(profile: _profile(layout: 'cards'));
    final c = await h.pump(tester, route: '/settings/home');
    expect(find.bySemanticsLabel(RegExp('^Kartlar, ')), findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp('^Kartlar, '))), isSemantics(isSelected: true, isInMutuallyExclusiveGroup: true));
    await tester.tap(find.text('Kısayollar'));
    await _load(tester);
    expect(c.read(profileProvider).app.layout, HomeLayout.grid);
    final saved = await tester.runAsync(() => h.repo.load());
    expect(saved!.app.layout, HomeLayout.grid);
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp('^Kısayollar, '))), isSemantics(isSelected: true));
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp('^Kartlar, '))), isSemantics(isSelected: false));

    await tester.tap(find.text('Odak'));
    await _load(tester);
    expect(c.read(profileProvider).app.layout, HomeLayout.focus);
    c.router.go('/');
    await _load(tester);
    expect(find.text('Durum'), findsOneWidget);
    expect(find.byType(ShortcutRow), findsWidgets);
    await _finish(tester);
  });

  testWidgets('kısayolu kapatınca ana ekrandan kalkar', (tester) async {
    final h = Harness(profile: _profile(layout: 'grid', shortcuts: ['vault', 'events']));
    final c = await h.pump(tester, route: '/settings/home');
    await _scrollTo(tester, 'Şifre kasası');
    final tile = find.ancestor(of: find.text('Şifre kasası'), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await _load(tester);
    expect(c.read(profileProvider).app.shortcuts, ['events']);
    c.router.go('/');
    await _load(tester);
    expect(find.byWidgetPredicate((w) => w is ShortcutTile && w.id == 'vault'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is ShortcutTile && w.id == 'events'), findsOneWidget);
    await _finish(tester);
  });

  testWidgets('kısayollar sürükleyerek sıralanır', (tester) async {
    final h = Harness(profile: _profile(layout: 'grid', shortcuts: ['vault', 'events', 'media']));
    final c = await h.pump(tester, route: '/settings/home');
    await _scrollTo(tester, 'Şifre kasası');
    final row = find.ancestor(of: find.text('Şifre kasası'), matching: find.byType(ListTile));
    // Bring the dragged row to the top half of the screen (below the pinned header, with room beneath it).
    // (Lazy list heights are estimated, so it settles over a few steps.)
    final pos = tester.state<ScrollableState>(_settingsScroll).position;
    for (var i = 0; i < 3; i++) {
      pos.jumpTo(pos.pixels + tester.getCenter(row).dy - 250);
      await tester.pump();
    }
    await settle(tester);
    expect(tester.getCenter(row).dy, inInclusiveRange(150, 400));
    final handle = find.descendant(of: row, matching: find.byType(ReorderableDragStartListener));
    final height = tester.getSize(row).height;
    final g = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(Offset(0, height * 2.6 / 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
    await g.up();
    await _load(tester);
    await _load(tester);
    expect(c.read(profileProvider).app.shortcuts, ['events', 'media', 'vault']);
    await _finish(tester);
  });

  testWidgets('kısayola dokununca doğru ekran açılır', (tester) async {
    final c = await Harness(profile: _profile(layout: 'grid', shortcuts: ['vault', 'events', 'compose', 'newClaude'])).pump(tester);
    String loc() => c.router.routerDelegate.currentConfiguration.last.matchedLocation;
    for (final (id, route) in [('vault', '/vault'), ('events', '/system/events'), ('compose', '/system/compose')]) {
      await tester.tap(find.byWidgetPredicate((w) => w is ShortcutTile && w.id == id));
      await _load(tester);
      expect(loc(), route);
      c.router.pop();
      await _load(tester);
    }
    expect(find.byType(EventsScreen), findsNothing);
    await tester.tap(find.byWidgetPredicate((w) => w is ShortcutTile && w.id == 'newClaude'));
    await _load(tester);
    expect(c.router.routerDelegate.currentConfiguration.uri.toString(), '/claude?new=1');
    await _finish(tester);
  });

  testWidgets('gereksinimi olmayan kısayol gizlenir, ayarlarda eksik yazar', (tester) async {
    final p = _profile(layout: 'grid', shortcuts: ['quickNote', 'vault']);
    final c = await Harness(profile: p.copyWith(integrations: p.integrations.copyWith(obsidian: () => null))).pump(tester);
    expect(find.byWidgetPredicate((w) => w is ShortcutTile && w.id == 'quickNote'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is ShortcutTile && w.id == 'vault'), findsOneWidget);
    c.router.go('/settings');
    await settle(tester);
    c.router.push('/settings/home');
    await settle(tester);
    await _scrollTo(tester, 'Obsidian kasası ayarlı değil');
    expect(find.text('Obsidian kasası ayarlı değil'), findsOneWidget);
    await _finish(tester);
  });
}
