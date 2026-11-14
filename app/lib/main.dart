import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/profile/codec.dart';
import 'core/profile/model.dart';
import 'core/profile/repository.dart';
import 'core/push/push_service.dart';
import 'core/secrets/secret_store.dart';
import 'core/security/app_lock.dart';
import 'features/files/share_to_pc.dart';
import 'features/settings/push_section.dart';
import 'state/providers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();

  final codec = ProfileCodec(await rootBundle.loadString('assets/profile/tiphys.schema.json'));
  final docs = await getApplicationDocumentsDirectory();
  final secrets = KeystoreSecretStore();
  final repo = ProfileRepository(file: File('${docs.path}/profile.json'), codec: codec, secrets: secrets);

  Future<Profile> loadProfile() async {
    try {
      return await repo.load();
    } catch (_) {
      return Profile.empty;
    }
  }

  final push = PushService(vault: const SecureVault(), loadProfile: loadProfile, secrets: secrets);

  // UnifiedPush mesajı uygulama kapalıyken geldiyse: sadece bildirimi göster, arayüzü açma.
  final background = args.contains('--unifiedpush-bg');
  await push.init(background: background);
  if (background) return;

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);

  Profile initial;
  try {
    initial = await repo.load();
  } catch (_) {
    // Bozuk dosya: kenara al, boş profille başla (kullanıcı yedeğini içe aktarabilir).
    final f = File('${docs.path}/profile.json');
    if (await f.exists()) await f.rename('${docs.path}/profile.broken-${DateTime.now().millisecondsSinceEpoch}.json');
    initial = Profile.empty;
  }

  final container = ProviderContainer(overrides: [
    secretStoreProvider.overrideWithValue(secrets),
    repositoryProvider.overrideWithValue(repo),
    initialProfileProvider.overrideWithValue(initial),
    pushServiceProvider.overrideWithValue(push),
  ]);

  // Bildirime dokununca ilgili ekran.
  push.onOpen = (route) => container.read(routerProvider).push(route);
  final launch = await push.launchRoute();
  // Uç nokta değişmiş ya da ajan yeni eşlenmiş olabilir: açılışta ajanlara tekrar bildir.
  push.registerWithAgents();

  runApp(UncontrolledProviderScope(container: container, child: const TiphysApp()));
  // Android "Paylaş" menüsünden gelen dosya/metin → PC'ye gönder ekranı.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ShareIntake().start((items) => container.read(routerProvider).push('/share', extra: items));
  });
  if (launch != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => container.read(routerProvider).push(launch));
  }
}
