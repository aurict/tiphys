// Wake-on-LAN: sihirli paket. "Gönderen" bir ajan ise ona istek atılır; değilse telefon aynı yerel
// ağdaysa paketi kendisi yayınlar.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import 'agent_providers.dart';

Uint8List magicPacket(String mac) {
  final hex = mac.replaceAll(RegExp(r'[:-]'), '');
  if (!RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(hex)) throw ArgumentError('MAC');
  final bytes = [for (var i = 0; i < 12; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  return Uint8List.fromList([...List.filled(6, 0xFF), for (var i = 0; i < 16; i++) ...bytes]);
}

Future<void> sendLocalMagicPacket(String mac, {String broadcast = '255.255.255.255', int port = 9}) async {
  final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    sock.broadcastEnabled = true;
    final packet = magicPacket(mac);
    for (var i = 0; i < 3; i++) {
      sock.send(packet, InternetAddress(broadcast), port);
    }
  } finally {
    sock.close();
  }
}

Future<String> wakeHost(WidgetRef ref, Host host, AppLocalizations l) async {
  final w = host.wake!;
  try {
    if (w.viaHostId != null) {
      await agentCall(ref, w.viaHostId!, 'POST', '/v1/wake/${host.id}');
    } else {
      await sendLocalMagicPacket(w.mac);
    }
    return l.systemWakeSent(host.name);
  } catch (e) {
    return agentErrorText(l, e);
  }
}
