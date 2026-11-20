// Has the setup wizard been seen (finished or skipped)? Stored in the secure key-value store, not in the profile:
// it belongs to this phone, not to an exported setup. The wizard opens on its own only while this is false and no host
// exists; main.dart marks it seen as soon as a host exists, so it never comes back after that.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/security/app_lock.dart';

const onboardingSeenKey = 'app:onboardingSeen';

/// Overridden in tests (memory).
final onboardingVaultProvider = Provider<KeyValueVault>((ref) => const SecureVault());

/// The stored value at startup (main.dart reads it before the first frame). Tests default to "seen".
final onboardingSeenInitialProvider = Provider<bool>((ref) => true);

class OnboardingSeen extends Notifier<bool> {
  @override
  bool build() => ref.read(onboardingSeenInitialProvider);

  Future<void> markSeen() async {
    if (state) return;
    state = true;
    await ref.read(onboardingVaultProvider).write(onboardingSeenKey, '1');
  }
}

final onboardingSeenProvider = NotifierProvider<OnboardingSeen, bool>(OnboardingSeen.new);

/// Startup: seen if stored, or if the profile already has a host (then it's stored too).
/// A store that can't be used (a Linux desktop without a Secret Service keyring) must not stop the app from starting:
/// then only the hosts decide.
Future<bool> loadOnboardingSeen(KeyValueVault vault, {required bool hasHosts}) async {
  try {
    if (await vault.read(onboardingSeenKey) != null) return true;
    if (hasHosts) unawaited(vault.write(onboardingSeenKey, '1').catchError((Object _) {}));
  } catch (e) {
    debugPrint('onboarding flag unavailable: $e');
  }
  return hasHosts;
}
