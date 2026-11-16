// Password vault: entries live on the device as ONE JSON in secure storage (Android Keystore-backed SecretStore);
// never written to the profile file (plain JSON), never logged. In the encrypted profile backup via [vaultSecretId].
import 'dart:convert';
import 'dart:math';

import '../secrets/secret_store.dart';

/// ID of the vault in secure storage.
const vaultSecretId = 'tiphys-vault';

class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.title,
    this.username = '',
    this.password = '',
    this.url = '',
    this.notes = '',
    this.tags = const [],
    required this.updatedAt,
  });
  final String id;
  final String title;
  final String username;
  final String password;
  final String url;
  final String notes;
  final List<String> tags;
  final DateTime updatedAt;

  factory VaultEntry.fromJson(Map j) => VaultEntry(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        username: (j['username'] as String?) ?? '',
        password: (j['password'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        notes: (j['notes'] as String?) ?? '',
        tags: ((j['tags'] as List?) ?? const []).whereType<String>().toList(),
        updatedAt: DateTime.tryParse('${j['updatedAt']}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'username': username,
        'password': password,
        'url': url,
        'notes': notes,
        'tags': tags,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  VaultEntry copyWith({String? title, String? username, String? password, String? url, String? notes, List<String>? tags, DateTime? updatedAt}) => VaultEntry(
        id: id,
        title: title ?? this.title,
        username: username ?? this.username,
        password: password ?? this.password,
        url: url ?? this.url,
        notes: notes ?? this.notes,
        tags: tags ?? this.tags,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// Keep passwords/notes out of debug output.
  @override
  String toString() => 'VaultEntry($id)';
}

class VaultFormatError implements Exception {
  const VaultFormatError();
}

/// Vault JSON: {"v":1,"entries":[…]}.
String encodeVault(List<VaultEntry> entries) => jsonEncode({'v': 1, 'entries': [for (final e in entries) e.toJson()]});

List<VaultEntry> decodeVault(String text) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['v'] != 1 || j['entries'] is! List) throw const VaultFormatError();
    return [for (final e in (j['entries'] as List).whereType<Map>()) VaultEntry.fromJson(e)];
  } on FormatException {
    throw const VaultFormatError();
  } on TypeError {
    throw const VaultFormatError();
  }
}

/// Merges two vaults (restoring from backup): by ID, the one with the newer update time wins.
List<VaultEntry> mergeVaults(List<VaultEntry> current, List<VaultEntry> incoming) {
  final byId = {for (final e in current) e.id: e};
  for (final e in incoming) {
    final c = byId[e.id];
    if (c == null || e.updatedAt.isAfter(c.updatedAt)) byId[e.id] = e;
  }
  return byId.values.toList();
}

class VaultStore {
  VaultStore(this.secrets);
  final SecretStore secrets;

  Future<List<VaultEntry>> load() async {
    final raw = await secrets.read(vaultSecretId);
    return raw == null ? <VaultEntry>[] : decodeVault(raw);
  }

  Future<void> save(List<VaultEntry> entries) => secrets.write(vaultSecretId, encodeVault(entries));
}

/// Random entry ID (128 bits).
String newVaultId([Random? random]) {
  final r = random ?? Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Search in title/user/address/tags (case-insensitive; every space-separated word must occur).
/// Passwords and notes are not searched.
List<VaultEntry> searchVault(List<VaultEntry> entries, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final sorted = [...entries]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  if (words.isEmpty) return sorted;
  return sorted.where((e) {
    final hay = [e.title, e.username, e.url, ...e.tags].join('\n').toLowerCase();
    return words.every(hay.contains);
  }).toList();
}

const _lowers = 'abcdefghijkmnopqrstuvwxyz';
const _uppers = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const _digits = '23456789';
const _symbols = r'!#$%&*+-=?@^_~.,:;';

/// Password generator (Random.secure). No look-alike characters (l, I, O, 0, 1); at least one char per class.
String generatePassword({int length = 20, bool symbols = true, Random? random}) {
  final r = random ?? Random.secure();
  final classes = [_lowers, _uppers, _digits, if (symbols) _symbols];
  final n = length.clamp(classes.length, 128);
  final all = classes.join();
  final chars = [for (final c in classes) c[r.nextInt(c.length)], for (var i = classes.length; i < n; i++) all[r.nextInt(all.length)]];
  // Fisher–Yates: so the required characters don't stay at the start.
  for (var i = chars.length - 1; i > 0; i--) {
    final j = r.nextInt(i + 1);
    final t = chars[i];
    chars[i] = chars[j];
    chars[j] = t;
  }
  return chars.join();
}
