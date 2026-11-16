// Loads real fonts in tests (instead of the default "Ahem" boxes), so that
// screenshots (goldens) can be compared against the design.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final f in manifest) {
    final family = (f as Map<String, dynamic>)['family'] as String;
    final loader = FontLoader(family);
    for (final asset in f['fonts'] as List<dynamic>) {
      loader.addFont(rootBundle.load((asset as Map<String, dynamic>)['asset'] as String));
    }
    await loader.load();
  }
  await testMain();
}
