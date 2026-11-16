import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/profile/model.dart';
import '../core/profile/repository.dart';
import '../core/secrets/secret_store.dart';

/// Replaced with real instances in main.dart (in-memory instances in tests).
final secretStoreProvider = Provider<SecretStore>((ref) => throw UnimplementedError());
final repositoryProvider = Provider<ProfileRepository>((ref) => throw UnimplementedError());
final initialProfileProvider = Provider<Profile>((ref) => Profile.empty);

class ProfileNotifier extends Notifier<Profile> {
  @override
  Profile build() => ref.read(initialProfileProvider);

  /// Changes the profile and saves it persistently.
  Future<void> update(Profile Function(Profile) change) async {
    final next = change(state);
    await ref.read(repositoryProvider).save(next);
    state = next;
  }

  /// Replaces directly after an import or reset (the caller has already done the saving).
  void replace(Profile p) => state = p;
}

final profileProvider = NotifierProvider<ProfileNotifier, Profile>(ProfileNotifier.new);

final themeModeProvider = Provider<ThemeMode>((ref) {
  return switch (ref.watch(profileProvider.select((p) => p.app.theme))) {
    ThemePref.system => ThemeMode.system,
    ThemePref.light => ThemeMode.light,
    ThemePref.dark => ThemeMode.dark,
  };
});

final localeProvider = Provider<Locale?>((ref) {
  return switch (ref.watch(profileProvider.select((p) => p.app.language))) {
    LanguagePref.system => null,
    LanguagePref.tr => const Locale('tr'),
    LanguagePref.en => const Locale('en'),
  };
});

/// Clock (fixed in tests so screenshots don't change every day).
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Stored secret ids (for the "missing" warning on Settings screens).
final secretIdsProvider = FutureProvider<Set<String>>((ref) {
  ref.watch(profileProvider);
  return ref.read(secretStoreProvider).ids();
});
