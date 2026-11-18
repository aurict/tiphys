// Security center: models, helpers and texts (PLAN.md §15). Every rule, category and error code has Turkish and English
// text; unknown rules show their id.
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/incidents/incident_texts.dart';
import 'package:tiphys/features/incidents/incidents_data.dart' show exactHostFor;
import 'package:tiphys/features/security/security_data.dart';
import 'package:tiphys/features/security/security_texts.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/security_fixtures.dart';

final _langs = <String, AppLocalizations>{'tr': AppLocalizationsTr(), 'en': AppLocalizationsEn()};

const _params = <String, Object>{
  'proto': 'tcp', 'port': 2222, 'addr': '0.0.0.0', 'process': 'example-app', 'value': 'yes', 'user': 'kiosk', 'count': 3, 'days': 9, 'exposed': 2,
  'keys': 'kernel.kptr_restrict,fs.suid_dumpable', 'container': 'example-web', 'example': '/tmp/example', 'path': '/home/alice/agent.json', 'mode': '644',
};

void main() {
  const host = Host(id: 'argo', name: 'argo', address: 'argo.example.org');

  group('modeller', () {
    test('özet: sayılar, hata ve bayatlık okunur', () {
      final st = FakeSecurityState();
      final orion = SecurityHostSummary(host, st.find('argo', 'orion')!.summary());
      expect(orion.score, 52);
      expect(orion.counts.critical, 1);
      expect(orion.counts.total, 6);
      expect(orion.changes, 2);
      expect(orion.band, SecurityBand.bad);
      expect(orion.lastError, isNull);
      final err = SecurityHostSummary(host, {...st.find('argo', 'orion')!.summary(), 'lastError': {'code': 'agent.security.timeout', 'at': '2026-11-14T10:00:00Z'}, 'stale': true});
      expect(err.lastError!.code, 'agent.security.timeout');
      expect(err.showStale, isTrue);
    });

    test('puan bantları: ≥85 iyi, ≥60 uyarı, altı kötü, null yok', () {
      expect(securityBand(100), SecurityBand.good);
      expect(securityBand(85), SecurityBand.good);
      expect(securityBand(84), SecurityBand.warn);
      expect(securityBand(60), SecurityBand.warn);
      expect(securityBand(59), SecurityBand.bad);
      expect(securityBand(0), SecurityBand.bad);
      expect(securityBand(null), SecurityBand.none);
    });

    test('ayrıntı: rapor bölümleri ve root olmayan denetimde null bölümler', () {
      final st = FakeSecurityState();
      final full = SecurityDetail(host, st.find('argo', 'orion')!.detail());
      expect(full.changes.map((c) => c.category), ['ports', 'authKeys']);
      expect(full.flaggedPorts, {'tcp/2222'});
      final r = full.report!;
      expect(r.listen!.where((l) => l.exposed).map((l) => l.spec), ['tcp/22', 'tcp/9000', 'tcp/2222']);
      expect(r.listen!.where((l) => l.filtered).map((l) => l.spec), ['tcp/9000']);
      expect(r.firewall!.defaultDeny, isFalse);
      expect(SecurityDetail(host, st.find('argo', 'self')!.detail()).report!.firewall, isNull);
      expect(r.sshd!['allowusers'], ['alice', 'deploy']);
      expect(r.passwords!['kiosk'], 'empty');
      expect(r.docker!.containers.first.risky, isTrue);
      expect(r.docker!.containers.first.socketMounted, isTrue);
      expect(r.docker!.containers.last.risky, isFalse);
      expect(r.suid!.single.path, '/usr/bin/sudo');
      final quick = SecurityDetail(host, st.find('argo', 'self')!.detail());
      expect(quick.report!.passwords, isNull);
      expect(quick.report!.sudoers, isNull);
      expect(quick.report!.suid, isNull);
      expect(quick.report!.unavailable, ['passwords', 'sudoers', 'autostart']);
      expect(SecurityDetail(host, {...st.find('argo', 'self')!.detail(), 'report': null}).report, isNull);
    });

    test('ayarlar: belirteç yalnız hasToken olarak gelir', () {
      final s = SecuritySettings(host, {
        'self': {'role': 'server', 'allowedPorts': ['tcp/22'], 'sudo': true},
        'hosts': [
          {'id': 'orion', 'name': 'orion', 'role': 'server', 'allowedPorts': <String>[], 'source': {'kind': 'agent', 'url': 'https://orion.example.org', 'hasToken': true}},
          {'id': 'atlas', 'name': 'atlas', 'role': 'desktop', 'allowedPorts': <String>[], 'source': {'kind': 'ssh', 'host': 'atlas.example.org', 'user': 'audit', 'port': 2200, 'keyPath': '/k'}},
        ],
      });
      expect(s.self.sudo, isTrue);
      expect(s.hosts.first.hasToken, isTrue);
      expect(s.hosts.first.isSsh, isFalse);
      expect(s.hosts.last.sshPort, 2200);
    });
  });

  group('yardımcılar', () {
    test('port biçimi', () {
      for (final ok in ['tcp/22', 'udp/53', 'tcp/65535', 'tcp/1']) {
        expect(validPortSpec(ok), isTrue, reason: ok);
      }
      for (final bad in ['22', 'tcp/', 'tcp/0', 'tcp/65536', 'TCP/22', 'icmp/1', 'tcp/123456', ' tcp/22', 'tcp/2x']) {
        expect(validPortSpec(bad), isFalse, reason: bad);
      }
    });

    test('kaynak gövdesi: belirteç yalnız yazıldıysa gider', () {
      expect(securitySourceBody(ssh: false, url: ' https://orion.example.org ', token: ''), {'kind': 'agent', 'url': 'https://orion.example.org'});
      expect(securitySourceBody(ssh: false, url: 'https://orion.example.org', token: 'tps_example'), {'kind': 'agent', 'url': 'https://orion.example.org', 'token': 'tps_example'});
      expect(securitySourceBody(ssh: true, host: 'orion.example.org', user: 'audit', port: 2200, keyPath: '/k'), {'kind': 'ssh', 'host': 'orion.example.org', 'user': 'audit', 'port': 2200, 'keyPath': '/k'});
    });

    test('ad ile bulma ve yollar', () {
      final st = FakeSecurityState();
      final hosts = [for (final h in st.hosts['argo']!) SecurityHostSummary(host, h.summary())];
      expect(securityHostByName(hosts, 'ORION')?.id, 'orion');
      expect(securityHostByName(hosts, 'nope'), isNull);
      expect(securityRoute('orion', agentId: 'atlas'), '/security/orion?host=atlas');
      expect(securityRoute('orion'), '/security/orion');
      expect(securityRoute('Argo PC'), '/security/Argo%20PC');
    });

    test('zaman aşımı: tam denetim ≥330 sn, diğeri ≥120 sn', () {
      expect(securityCheckTimeout(full: true).inSeconds, greaterThanOrEqualTo(330));
      expect(securityCheckTimeout(full: false).inSeconds, greaterThanOrEqualTo(120));
    });

    test('bildirim bağlantısı ve olay odası türü', () {
      expect(routeForLink('tiphys://security/orion'), '/security/orion');
      expect(routeForLink('tiphys://security'), '/security');
      expect(routeForLink('tiphys://security/Bad_Id'), isNull);
      expect(incidentFamily('security.change'), 'security');
      expect(incidentFamilies, contains('security'));
    });
  });

  for (final MapEntry(key: lang, value: l) in _langs.entries) {
    group('metinler ($lang)', () {
      test('her kuralın başlığı, açıklaması ve önerisi var', () {
        for (final r in securityRules) {
          final title = securityRuleTitle(l, r, _params);
          expect(title, isNotEmpty, reason: r);
          expect(title, isNot(r), reason: '$r başlığı çevrilmiş olmalı');
          expect(securityRuleWhy(l, r, _params), isNotEmpty, reason: r);
          expect(securityRuleFix(l, r), isNotEmpty, reason: r);
        }
        expect(securityRuleTitle(l, 'port.exposed', _params), contains('tcp/2222'));
        expect(securityRuleWhy(l, 'port.exposed', _params), allOf(contains('example-app'), contains('0.0.0.0')));
        expect(securityRuleWhy(l, 'port.exposed', _params)!.indexOf('example-app'), lessThan(securityRuleWhy(l, 'port.exposed', _params)!.indexOf('0.0.0.0')));
        expect(securityRuleTitle(l, 'port.exposed', {..._params, 'firewall': 'unknown'}), contains(l.secFirewallUnknownSuffix));
        expect(securityRuleWhy(l, 'port.exposed', {..._params, 'process': null}), isNot(contains('example-app')));
        expect(securityRuleTitle(l, 'docker.socket', _params), contains('example-web'));
        expect(securityRuleWhy(l, 'sysctl.weak', _params), contains('kernel.kptr_restrict, fs.suid_dumpable'));
      });

      test('bilinmeyen kural kimliğini gösterir', () {
        expect(securityRuleTitle(l, 'some.futureRule', const {}), 'some.futureRule');
        expect(securityRuleWhy(l, 'some.futureRule', const {}), isNull);
        expect(securityRuleFix(l, 'some.futureRule'), isNull);
      });

      test('her değişiklik kategorisi, türü, önem ve kapsam adı var', () {
        for (final c in securityCategories) {
          expect(securityCategoryName(l, c), isNot(c), reason: c);
        }
        for (final k in ['added', 'removed', 'changed']) {
          expect(securityKindName(l, k), isNot(k));
        }
        for (final s in securityFindingSeverities) {
          expect(securitySeverityName(l, s), isNot(s));
        }
        for (final s in ['wildcard', 'public', 'tailscale', 'loopback', 'linklocal']) {
          expect(securityScopeName(l, s), isNot(s));
        }
        expect(securityScopeName(l, 'private'), lang == 'tr' ? 'özel' : 'private');
      });

      test('her agent.security.* hata kodunun metni var', () {
        for (final c in securityErrorCodes) {
          expect(securityErrorText(l, 'agent.security.$c'), isNot(contains('agent.security')), reason: c);
        }
        expect(securityErrorText(l, 'agent.security.future'), contains('agent.security.future'));
      });

      test('bildirimler', () {
        final change = securityNoticeText(l, 'security.change', {'host': 'orion', 'hostId': 'orion', 'count': 2, 'categories': 'ports,authKeys', 'severity': 'critical'})!;
        expect(change.$1, contains('orion'));
        expect(change.$2, contains(securityCategoryName(l, 'ports')));
        expect(change.$2, contains(securityCategoryName(l, 'authKeys')));
        final warn = securityNoticeText(l, 'security.change', {'host': 'orion', 'count': 1, 'categories': 'cron', 'severity': 'warning'})!;
        expect(warn.$1, isNot(change.$1));
        expect(securityNoticeText(l, 'security.accepted', {'host': 'orion', 'hostId': 'orion', 'count': 2})!.$2, contains('2'));
        final un = securityNoticeText(l, 'security.unreachable', {'host': 'orion', 'hours': 7, 'code': 'agent.security.sshFailed'})!;
        expect(un.$2, contains('7'));
        expect(un.$2, contains(securityErrorText(l, 'agent.security.sshFailed')));
        expect(securityNoticeText(l, 'security.reachable', {'host': 'orion'})!.$1, contains('orion'));
        expect(noticeText(l, 'security.change', {'host': 'orion', 'count': 1, 'categories': 'cron'}), isNotNull, reason: 'push metni noticeText ile gelir');
        expect(securityNoticeText(l, 'claude.done', const {}), isNull);
      });

      test('olay odası: güvenlik türü', () {
        expect(incidentTitle(l, 'security.change', 'orion'), contains('orion'));
        expect(incidentFamilyName(l, 'security'), isNot('security'));
        expect(l.incOpenSecurity, isNotEmpty);
      });
    });
  }

  test('bildirim: params.agent ajan ipucu olarak yola eklenir; yoksa ipucusuz', () {
    final payload = securityPayload('security.change', 'tiphys://security/orion', {'host': 'Orion', 'hostId': 'orion', 'agent': 'argo (PC)'});
    expect(routeForPayload(payload), '/security/orion?host=argo+%28PC%29');
    // The hint is matched with the same logic as incident links.
    const argo = Host(id: 'argo', name: 'argo (PC)', address: 'argo.example.org');
    const atlas = Host(id: 'atlas', name: 'atlas', address: 'atlas.example.org');
    expect(exactHostFor([argo, atlas], 'argo (PC)')?.id, 'argo');
    expect(securityRoute('orion', agentId: 'argo (PC)'), '/security/orion?host=argo+%28PC%29');
    // An incident link keeps its own route but takes the agent as the hint.
    expect(routeForPayload(securityPayload('security.change', 'tiphys://incidents/inc-aaaaaaaaaaaa', {'host': 'orion', 'agent': 'atlas'})), '/incidents/inc-aaaaaaaaaaaa?host=atlas');
    expect(routeForPayload(securityPayload('security.change', 'tiphys://security/orion', {'host': 'orion'})), isNull);
    expect(routeForPayload('tiphys://security/orion'), '/security/orion');
    expect(securityPayload('claude.done', 'tiphys://claude/x', {'agent': 'argo'}), isNull);
  });

  for (final MapEntry(key: lang, value: l) in _langs.entries) {
    test('alınamayan bölüm adları ve istek hatası ($lang)', () {
      for (final id in securitySectionIds) {
        expect(securitySectionName(l, id), isNot(id), reason: id);
      }
      expect(securitySectionName(l, 'future'), 'future');
      expect(l.agentRequestInvalid, isNot(contains('agent.')));
    });
  }

  test('Türkçe başlıklar', () {
    final tr = _langs['tr']!;
    expect(tr.secTitle, 'Güvenlik merkezi');
    expect(tr.secRowTitle, 'Güvenlik');
    expect(tr.secCheckNow, 'Şimdi denetle');
    expect(tr.secCheckFull, 'Tam denetim');
    expect(tr.secAccept, 'Bu durumu kabul et');
    expect(tr.incOpenSecurity, 'Güvenlik ekranını aç');
    expect(incidentTitle(tr, 'security.change', 'orion'), startsWith('Güvenlik değişikliği'));
  });
}
