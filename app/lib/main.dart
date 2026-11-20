import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'core/platform.dart';
import 'core/profile/codec.dart';
import 'core/profile/model.dart';
import 'core/profile/repository.dart';
import 'core/push/push_service.dart';
import 'core/secrets/secret_store.dart';
import 'core/security/app_lock.dart';
import 'features/claude/pc_ongoing.dart';
import 'features/databases/db_data.dart' show dbClearCsvCopiesProvider;
import 'features/files/share_to_pc.dart';
import 'features/onboarding/onboarding_state.dart';
import 'features/settings/push_section.dart';
import 'state/providers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();

  final codec = ProfileCodec(await rootBundle.loadString('assets/profile/tiphys.schema.json'));
  final docs = await appDataDirectory();
  await docs.create(recursive: true); // the desktop support folder doesn't exist on first start
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

  // If a UnifiedPush message arrived while the app was closed: only show the notification, don't open the UI.
  final background = hasUnifiedPush && args.contains('--unifiedpush-bg');
  await push.init(background: background);
  if (background) return;

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);

  Profile initial;
  try {
    initial = await repo.load();
  } catch (_) {
    // Corrupt file: set it aside, start with an empty profile (the user can import their backup).
    final f = File('${docs.path}/profile.json');
    if (await f.exists()) await f.rename('${docs.path}/profile.broken-${DateTime.now().millisecondsSinceEpoch}.json');
    initial = Profile.empty;
  }

  final onboardingSeen = await loadOnboardingSeen(const SecureVault(), hasHosts: initial.hosts.isNotEmpty);

  final container = ProviderContainer(overrides: [
    secretStoreProvider.overrideWithValue(secrets),
    repositoryProvider.overrideWithValue(repo),
    initialProfileProvider.overrideWithValue(initial),
    pushServiceProvider.overrideWithValue(push),
    onboardingSeenInitialProvider.overrideWithValue(onboardingSeen),
  ]);

  // CSV exports of the database console left in the cache (an export or share cut short by a kill).
  unawaited(container.read(dbClearCsvCopiesProvider)());

  // Tapping a notification opens the related screen.
  push.onOpen = (route) => container.read(routerProvider).push(route);
  // Claude using the PC: notification buttons and the agent's "control finished" notification run off UI state.
  push.onPcAction = (action) => container.read(pcOngoingProvider.notifier).action(action);
  push.onPcEnded = (sessionId) => container.read(pcOngoingProvider.notifier).ended(sessionId);
  final launch = await push.launchRoute();
  // The endpoint may have changed or an agent may be newly paired: notify the agents again on startup.
  push.registerWithAgents();

  runApp(UncontrolledProviderScope(container: container, child: const TiphysApp()));
  // File/text from the Android "Share" menu → send-to-PC screen.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    ShareIntake().start((items) => container.read(routerProvider).push('/share', extra: items));
  });
  if (launch != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) => container.read(routerProvider).push(launch));
  }
}
