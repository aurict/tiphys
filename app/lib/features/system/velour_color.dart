// Velour player colours: the cover's dominant colour, toned down for a dark background that keeps white text readable.
// The cover is decoded at 24×24 (Flutter's own image cache and decoder; no package). Pure parts are unit tested.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The most colourful frequent colour of RGBA pixels: 12 hue buckets weighted by saturation, near-grey/black/white pixels
/// count little. Null if there are no pixels.
Color? dominantColor(Uint8List rgba) {
  if (rgba.length < 4) return null;
  final weight = List<double>.filled(13, 0);
  final sum = List.generate(13, (_) => [0.0, 0.0, 0.0]);
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));
    // Grey-ish pixels go to bucket 12 with a small weight; colourful mid-tones count most.
    final colourful = hsl.saturation > 0.2 && hsl.lightness > 0.12 && hsl.lightness < 0.88;
    final bucket = colourful ? (hsl.hue / 30).floor() % 12 : 12;
    final w = colourful ? 0.3 + hsl.saturation * (1 - (hsl.lightness - 0.5).abs()) : 0.08;
    weight[bucket] += w;
    sum[bucket][0] += r * w;
    sum[bucket][1] += g * w;
    sum[bucket][2] += b * w;
  }
  var best = 0;
  for (var i = 1; i < 13; i++) {
    if (weight[i] > weight[best]) best = i;
  }
  if (weight[best] == 0) return null;
  final w = weight[best];
  return Color.fromARGB(255, (sum[best][0] / w).round(), (sum[best][1] / w).round(), (sum[best][2] / w).round());
}

/// Background tone for the player: the colour's hue, lightness at most 0.30 and lowered further until white text on
/// it is above 7:1 (relative luminance ≤ 0.1; bright hues like yellow need a darker tone).
Color playerTone(Color c) {
  var hsl = HSLColor.fromColor(c);
  hsl = hsl.withLightness(hsl.lightness.clamp(0.16, 0.30)).withSaturation(hsl.saturation.clamp(0.0, 0.75));
  while (hsl.toColor().computeLuminance() > 0.1 && hsl.lightness > 0.05) {
    hsl = hsl.withLightness(hsl.lightness - 0.02);
  }
  return hsl.toColor();
}

/// The cover's dominant colour (null: no cover, can't be loaded or no colour in it).
final velourCoverColorProvider = FutureProvider.autoDispose.family<Color?, String>((ref, url) async {
  final provider = ResizeImage(NetworkImage(url), width: 24, height: 24);
  final done = Completer<ui.Image?>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!done.isCompleted) done.complete(info.image.clone());
      stream.removeListener(listener);
    },
    onError: (_, _) {
      if (!done.isCompleted) done.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  final image = await done.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
  if (image == null) return null;
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bytes == null ? null : dominantColor(bytes.buffer.asUint8List());
  } finally {
    image.dispose();
  }
});
