import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/integrations/dozzle_client.dart';

void main() {
  test('Dozzle cpu tam sayı gelirse (boştaki container) double olarak okunur', () {
    final c = DozzleContainer(Map<String, dynamic>.from(jsonDecode('{"stats":[{"cpu":0,"memoryUsage":146026496}]}') as Map));
    expect(c.cpu, 0.0);
    expect(c.memoryBytes, 146026496);
  });
}
