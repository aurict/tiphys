// .tiphys.json okuma/yazma: biçim kontrolü → sürüm taşıma → JSON Schema doğrulaması → model.
import 'dart:convert';

import 'package:json_schema/json_schema.dart';

import 'model.dart';

sealed class ProfileError implements Exception {
  const ProfileError();
}

class NotJson extends ProfileError {
  const NotJson();
}

class NotAProfile extends ProfileError {
  const NotAProfile();
}

class NewerSchema extends ProfileError {
  const NewerSchema(this.version);
  final int version;
}

class InvalidProfile extends ProfileError {
  const InvalidProfile(this.issues);
  final List<String> issues;
  @override
  String toString() => 'InvalidProfile(${issues.join('; ')})';
}

/// Okunmuş, doğrulanmış (ama varsayılanlarla doldurulmamış) dosya. Kısmi olabilir.
class ProfileFile {
  const ProfileFile(this.json);
  final Json json;

  bool has(String section) => json.containsKey(section);
  Map<String, dynamic>? get encryptedSecrets =>
      json['encryptedSecrets'] == null ? null : Map<String, dynamic>.from(json['encryptedSecrets'] as Map);

  /// Dosyadaki bölümleri varsayılanlarla doldurulmuş tam profile çevirir.
  Profile toProfile() => Profile.fromJson(json);
}

class ProfileCodec {
  ProfileCodec(String schemaJson) : _schema = JsonSchema.create(jsonDecode(schemaJson));
  final JsonSchema _schema;

  /// Sürüm taşımaları: schemaVersion N → N+1. Şimdilik sadece sürüm 1 var.
  static final Map<int, Json Function(Json)> migrations = {};

  ProfileFile decode(String text) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      throw const NotJson();
    }
    if (raw is! Map || raw['format'] != profileFormat || raw['schemaVersion'] is! int) {
      throw const NotAProfile();
    }
    var json = Map<String, dynamic>.from(raw);
    var v = json['schemaVersion'] as int;
    if (v > schemaVersion) throw NewerSchema(v);
    while (v < schemaVersion) {
      final m = migrations[v];
      if (m == null) throw NotAProfile();
      json = m(json);
      v = json['schemaVersion'] as int;
    }
    final result = _schema.validate(json);
    if (!result.isValid) {
      throw InvalidProfile(result.errors.map((e) => '${e.instancePath.isEmpty ? '/' : e.instancePath}: ${e.message}').toList());
    }
    _checkReferences(json);
    return ProfileFile(json);
  }

  /// Şemanın göremediği tutarlılıklar: yinelenen kimlikler, var olmayan hostlara başvuru.
  void _checkReferences(Json json) {
    final issues = <String>[];
    void unique(String path, List? list) {
      final ids = <String>{};
      for (final e in list ?? const []) {
        final id = (e as Map)['id'] as String;
        if (!ids.add(id)) issues.add('$path: "$id" kimliği birden fazla');
      }
    }

    final hosts = json['hosts'] as List?;
    unique('/hosts', hosts);
    unique('/keys', json['keys'] as List?);
    unique('/quickActions', json['quickActions'] as List?);
    final integ = json['integrations'] as Map?;
    unique('/integrations/grafana', integ?['grafana'] as List?);
    unique('/integrations/dozzle', integ?['dozzle'] as List?);

    // Host başvuruları sadece dosya host listesini içeriyorsa kontrol edilir (kısmi dosya mevcut hostlara başvurabilir).
    if (hosts != null) {
      final hostIds = hosts.map((h) => (h as Map)['id'] as String).toSet();
      void ref(String path, Object? id) {
        if (id is String && !hostIds.contains(id)) issues.add('$path: "$id" adlı host yok');
      }

      for (final h in hosts) {
        ref('/hosts/${(h as Map)['id']}/wake/viaHostId', (h['wake'] as Map?)?['viaHostId']);
      }
      ref('/claude/agentHostId', (json['claude'] as Map?)?['agentHostId']);
      ref('/integrations/homepage/source/hostId', ((integ?['homepage'] as Map?)?['source'] as Map?)?['hostId']);
      ref('/integrations/uptimeKuma/viaHostId', (integ?['uptimeKuma'] as Map?)?['viaHostId']);
      for (final q in (json['quickActions'] as List?) ?? const []) {
        ref('/quickActions/${(q as Map)['id']}/hostId', q['hostId']);
      }
      for (final b in ((json['files'] as Map?)?['bookmarks'] as List?) ?? const []) {
        ref('/files/bookmarks', (b as Map)['hostId']);
      }
    }
    if (issues.isNotEmpty) throw InvalidProfile(issues);
  }

  /// Profili dosya metnine çevirir. Gizli bilgi bölümü sadece şifreli yedekte eklenir.
  String encode(Profile p, {Json? encryptedSecrets, String? exportedFrom, DateTime? now}) {
    final json = <String, dynamic>{
      r'$schema': './schema/tiphys.schema.json',
      ...p.toJson(),
      'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'exportedFrom': ?exportedFrom,
      'encryptedSecrets': encryptedSecrets,
    };
    final result = _schema.validate(json);
    if (!result.isValid) {
      throw InvalidProfile(result.errors.map((e) => '${e.instancePath}: ${e.message}').toList());
    }
    return const JsonEncoder.withIndent('  ').convert(json);
  }
}
