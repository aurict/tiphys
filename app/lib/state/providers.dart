import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/profile/model.dart';
import '../core/profile/repository.dart';
import '../core/secrets/secret_store.dart';

/// main.dart'ta gerçek örneklerle değiştirilir (testlerde bellek örnekleri).
final secretStoreProvider = Provider<SecretStore>((ref) => throw UnimplementedError());
final repositoryProvider = Provider<ProfileRepository>((ref) => throw UnimplementedError());
final initialProfileProvider = Provider<Profile>((ref) => Profile.empty);

class ProfileNotifier extends Notifier<Profile> {
  @override
  Profile build() => ref.read(initialProfileProvider);

  /// Profili değiştirir ve kalıcı olarak kaydeder.
  Future<void> update(Profile Function(Profile) change) async {
    final next = change(state);
    await ref.read(repositoryProvider).save(next);
    state = next;
  }

  /// İçe aktarma ya da sıfırlama sonrası doğrudan değiştirir (kaydetme işini çağıran yapmıştır).
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

/// Saat (testlerde sabitlenir; ekran görüntüleri her gün değişmesin).
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Saklanan gizli bilgi kimlikleri (Ayarlar ekranlarında "eksik" uyarısı için).
final secretIdsProvider = FutureProvider<Set<String>>((ref) {
  ref.watch(profileProvider);
  return ref.read(secretStoreProvider).ids();
});
