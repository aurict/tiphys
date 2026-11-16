// Small PNG generator for tests (RGBA, compressed); so screenshots decode a real image.
import 'dart:io';
import 'dart:typed_data';

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

List<int> _chunk(String type, List<int> data) {
  final body = [...type.codeUnits, ...data];
  final len = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc(body));
  return [...len.buffer.asUint8List(), ...body, ...crc.buffer.asUint8List()];
}

/// [pixel](x, y) → 0xAARRGGBB
Uint8List testPng(int w, int h, int Function(int x, int y) pixel) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // no filter
    for (var x = 0; x < w; x++) {
      final p = pixel(x, y);
      raw.add([(p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff, (p >> 24) & 0xff]);
    }
  }
  final ihdr = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  return Uint8List.fromList([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
    ..._chunk('IHDR', ihdr.buffer.asUint8List()),
    ..._chunk('IDAT', ZLibEncoder().convert(raw.takeBytes())),
    ..._chunk('IEND', const []),
  ]);
}

/// Colored app icon with rounded corners (a light circle in the middle).
Uint8List iconPng(int argb, {int size = 48}) {
  final r = size * 0.22, c = size / 2;
  return testPng(size, size, (x, y) {
    final dx = (x + 0.5 - c).abs() - (c - r), dy = (y + 0.5 - c).abs() - (c - r);
    final out = dx > 0 && dy > 0 && dx * dx + dy * dy > r * r;
    if (out) return 0;
    final inner = (x + 0.5 - c) * (x + 0.5 - c) + (y + 0.5 - c) * (y + 0.5 - c) < (size * 0.2) * (size * 0.2);
    return inner ? 0xF0FFFFFF : argb;
  });
}

/// Fake window thumbnail: title bar + lines.
Uint8List windowPng(int accent, {int w = 160, int h = 100, bool dark = false}) {
  final bg = dark ? 0xFF1E1E24 : 0xFFF7F7FA, line = dark ? 0xFF3A3A46 : 0xFFDADAE3;
  return testPng(w, h, (x, y) {
    if (y < 12) return accent;
    if (x < 34) return dark ? 0xFF26262E : 0xFFECECF2;
    final row = (y - 20) % 12;
    if (y > 18 && row < 5 && x > 42 && x < w - 10 - ((y ~/ 12) % 3) * 22) return line;
    return bg;
  });
}
