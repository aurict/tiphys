// Both language files must have the same keys; a missing translation stops the test (and the build script).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Set<String> keys(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>).keys.where((k) => !k.startsWith('@')).toSet();

void main() {
  test('Türkçe ve İngilizce anahtarlar aynı', () {
    final en = keys('lib/l10n/app_en.arb');
    final tr = keys('lib/l10n/app_tr.arb');
    expect(en.difference(tr), isEmpty, reason: 'Türkçede eksik');
    expect(tr.difference(en), isEmpty, reason: 'İngilizcede eksik');
  });

  test('yer tutucular iki dilde de aynı', () {
    final en = jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync()) as Map<String, dynamic>;
    final tr = jsonDecode(File('lib/l10n/app_tr.arb').readAsStringSync()) as Map<String, dynamic>;
    for (final k in en.keys.where((k) => !k.startsWith('@'))) {
      final meta = en['@$k'] as Map<String, dynamic>?;
      final names = ((meta?['placeholders'] as Map<String, dynamic>?) ?? {}).keys;
      for (final n in names) {
        expect((tr[k] as String).contains('{$n'), isTrue, reason: '$k: Türkçede {$n} yok');
      }
    }
  });
}
