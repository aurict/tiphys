// The app's Claude live stream against the real agent (with a "continue" session that makes no API calls).
@Tags(['real'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/features/claude/claude_controller.dart';

import 'real_env.dart';

void main() {
  setUpAll(() => HttpOverrides.global = null);

  test('WebSocket bağlanır, birikmiş olayları alır, oturum kapatılır', () async {
    final client = AgentClient(baseUrl: real.agent(real.pc), token: File(real.pcToken).readAsStringSync().trim());
    final list = await client.get('/v1/claude/sessions');
    final past = (list['history'] as List).cast<Map>().first;
    final s = await client.post('/v1/claude/sessions', {'cwd': '~', 'resume': past['sdkSessionId'], 'permissionMode': 'plan'}) as Map;
    final c = ClaudeSessionController(client: client, sessionId: '${s['id']}');
    try {
      await c.start();
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (!c.connected && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(c.connected, isTrue);
      expect(c.events.any((e) => e.kind == 'status'), isTrue);
      expect(c.summary!['permissionMode'], 'plan');
    } finally {
      await client.delete('/v1/claude/sessions/${s['id']}');
      c.dispose();
    }
  });
}
