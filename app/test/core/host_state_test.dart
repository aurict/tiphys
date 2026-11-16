import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/codec.dart';
import 'package:tiphys/features/home/home_data.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/state/providers.dart';
import 'package:tiphys/widgets/painters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final codec = ProfileCodec(File('assets/profile/tiphys.schema.json').readAsStringSync());
  // example profile: argo + atlas with agent, orion SSH only
  final profile = codec.decode(File('assets/profile/example.json').readAsStringSync()).toProfile();

  ProviderContainer make({required Set<String> healthyAgents, required Set<String> openSsh}) {
    final c = ProviderContainer(overrides: [
      initialProfileProvider.overrideWithValue(profile),
      agentHealthFnProvider.overrideWithValue((url) async {
        if (healthyAgents.any(url.contains)) return {'name': 'x'};
        throw const SocketException('down');
      }),
      tcpProbeProvider.overrideWithValue((host, port) async => openSsh.any(host.contains)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<Map<String, HostState>> states(ProviderContainer c) async {
    final subs = [for (final h in profile.hosts) c.listen(hostStateProvider(h.id), (_, _) {})];
    for (final h in profile.hosts) {
      await c.read(hostStateProvider(h.id).future);
    }
    final m = c.read(homeDataProvider).hostStates;
    for (final s in subs) {
      s.close();
    }
    return m;
  }

  test('ajan sağlık ucu cevap verirse host çevrim içi (eşleşme gerekmez)', () async {
    final m = await states(make(healthyAgents: {'argo', 'atlas'}, openSsh: {'orion'}));
    expect(m, {'argo': HostState.online, 'atlas': HostState.online, 'orion': HostState.online});
  });

  test('ajan kapalıysa SSH portuna bakılır, o da kapalıysa çevrim dışı', () async {
    final m = await states(make(healthyAgents: {}, openSsh: {'atlas'}));
    expect(m, {'argo': HostState.offline, 'atlas': HostState.online, 'orion': HostState.offline});
  });
}
