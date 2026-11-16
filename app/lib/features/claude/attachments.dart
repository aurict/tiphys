// Attachments for Claude: gallery photo (downscaled if needed) and voice message (recording → agent → Whisper → text).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class ImageAttachment {
  const ImageAttachment({required this.name, required this.mediaType, required this.bytes});
  final String name;
  final String mediaType;
  final Uint8List bytes;

  Map<String, String> toJson() => {'mediaType': mediaType, 'data': base64Encode(bytes)};
}

/// Upper limit (long edge and bytes) based on the size the Claude API accepts.
const _maxSide = 1568;
const _maxBytes = 4 * 1024 * 1024;

Future<List<ImageAttachment>> pickImages() async {
  final files = await FilePicker.pickFiles(type: FileType.image);
  final out = <ImageAttachment>[];
  for (final f in files.take(5)) {
    out.add(await prepareImage(f.name, await f.readAsBytes()));
  }
  return out;
}

/// Kept as is if the format and size are supported; otherwise converted to PNG with a 1568 px long edge.
Future<ImageAttachment> prepareImage(String name, Uint8List data) async {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  final type = switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    _ => null,
  };
  final codec = await ui.instantiateImageCodec(data);
  final frame = await codec.getNextFrame();
  final w = frame.image.width, h = frame.image.height;
  frame.image.dispose();
  codec.dispose();
  if (type != null && data.length <= _maxBytes && w <= _maxSide && h <= _maxSide) {
    return ImageAttachment(name: name, mediaType: type, bytes: data);
  }
  final scale = _maxSide / (w > h ? w : h);
  final c2 = await ui.instantiateImageCodec(data, targetWidth: scale < 1 ? (w * scale).round() : w, targetHeight: scale < 1 ? (h * scale).round() : h);
  final f2 = await c2.getNextFrame();
  final png = await f2.image.toByteData(format: ui.ImageByteFormat.png);
  f2.image.dispose();
  c2.dispose();
  return ImageAttachment(name: name, mediaType: 'image/png', bytes: png!.buffer.asUint8List());
}

/// Voice message recording (AAC/M4A, 16 kHz mono: enough for speech and small).
class VoiceRecorder extends ChangeNotifier {
  /// The microphone plugin is created on the first recording (not when the chat opens).
  AudioRecorder? _rec;
  DateTime? startedAt;
  String? _path;
  Timer? _tick;

  bool get recording => startedAt != null;
  Duration get elapsed => startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  /// Returns false if there is no permission.
  Future<bool> start() async {
    final rec = _rec ??= AudioRecorder();
    if (!await rec.hasPermission()) return false;
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/tiphys-ses-${DateTime.now().millisecondsSinceEpoch}.m4a';
    await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1, bitRate: 48000), path: _path!);
    startedAt = DateTime.now();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => notifyListeners());
    notifyListeners();
    return true;
  }

  /// Stops the recording and returns the file's bytes (the file is deleted).
  Future<Uint8List?> stop() async {
    _tick?.cancel();
    final path = await _rec?.stop() ?? _path;
    startedAt = null;
    notifyListeners();
    if (path == null) return null;
    final f = File(path);
    final bytes = await f.readAsBytes();
    await f.delete().catchError((_) => f);
    return bytes;
  }

  Future<void> cancel() async {
    _tick?.cancel();
    await _rec?.cancel();
    startedAt = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _rec?.dispose();
    super.dispose();
  }
}
