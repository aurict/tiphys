// Security center S-2…S-5: models, texts (every id has Turkish and English text), deep links and the token-less lockdown call.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/security/security_data.dart' show securityRoute;
import 'package:tiphys/features/security/security_more_data.dart';
import 'package:tiphys/features/security/security_more_texts.dart';
import 'package:tiphys/features/security/security_texts.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';
import 'package:tiphys/l10n/gen/app_localizations_en.dart';
import 'package:tiphys/l10n/gen/app_localizations_tr.dart';

import '../helpers/security_more_fixtures.dart';

final _langs = <String, AppLocalizations>{
  'tr': AppLocalizationsTr(),
  'en': AppLocalizationsEn(),
};

/// The test binding answers every HTTP request with 400; this one lets a loopback server be reached.
class _RealHttp extends HttpOverrides {}

void main() {
  test('host ekranı yolu: bölüm adıyla çakışan ad genel bakışa gider', () {
    expect(securityRoute('orion', agentId: 'atlas'), '/security/orion?host=atlas');
    expect(securityRoute('self'), '/security/self');
    expect(securityRoute('vulns', agentId: 'atlas'), '/security?host=atlas');
    expect(securityRoute('traps'), '/security');
  });

  group('modeller', () {
    final st = FakeSecurityMoreState();

    test('açıklar: sayılar, hex, durum ve nedenler', () {
      final list = VulnList({
        'enabled': true,
        'running': false,
        'images': [
          for (final i in st.images) {...i}..remove('vulns'),
        ],
      });
      expect(list.images.first.hex, 'a' * 64);
      expect(list.images.first.critical, 2);
      expect(list.images.map((i) => i.status).toSet().difference(vulnStatuses.toSet()), isEmpty);
      expect(list.images[1].error, 'ghcr.io');
      expect(VulnImage(st.images.first).vulns.first.severity, 'critical');
      expect(VulnImage(st.images.first).vulns[1].fixed, isNull);
    });

    test('sırlar: değer alanı yok, yoksayılanlar ayrılır, kaynak hataları', () {
      final s = SecretsData(st.secrets);
      expect(s.open.length, 2);
      expect(s.dismissed.single.rule, 'private-key');
      expect(s.sourceErrors['loki'], 'agent.security.lokiUnavailable');
      expect(s.findings.first.location, 'config/old.env:12');
      expect(SecretsData({'lastRun': null, 'findings': []}).hasRun, isFalse);
    });

    test('sırlar: kaynak+yer+kural+klasör (Loki: akış) ile gruplanır; gövde pathPrefix/stream', () {
      Map<String, dynamic> f(String id, String src, String? file, {String? stream}) => {'id': id * 24, 'source': src, 'rule': 'r', 'where': 'w', 'file': file, 'stream': stream, 'dismissed': false};
      final g = groupSecretFindings([
        for (final x in [f('a', 'github', 'a/b/x.env'), f('b', 'github', 'a/b/y.env'), f('c', 'github', 'a/z.env'), f('d', 'local', 'root.env'), f('e', 'loki', null, stream: 'c=api'), f('f', 'loki', null, stream: 'c=api')]) SecretFindingItem(x),
      ]);
      expect(g.map((x) => x.items.length), [2, 1, 1, 2]);
      expect(g[0].body(), {'source': 'github', 'where': 'w', 'rule': 'r', 'pathPrefix': 'a/b/'});
      expect(g[2].body(), {'source': 'local', 'where': 'w', 'rule': 'r'});
      expect(g[3].body(), {'source': 'loki', 'where': 'w', 'rule': 'r', 'stream': 'c=api'});
    });

    test('tarayıcı ayarları: belirteç yalnız hasToken; Loki kipleri', () {
      final c = ScannersConfig(st.scanners['atlas']!);
      expect(c.githubToken, isTrue);
      expect(c.registryAuth.single.hasToken, isTrue);
      expect(c.lokiMode, 'container');
      expect(
        ScannersConfig({
          'loki': {'url': 'https://loki.example.org'},
        }).lokiMode,
        'url',
      );
      expect(ScannersConfig({}).lokiMode, 'off');
      expect(c.nightFrom, 2);
      expect(
        registryAuthBody([
          ('ghcr.io', 'u', null),
          ('r.example.org', 'v', 'tok'),
        ]),
        [
          {'registry': 'ghcr.io', 'username': 'u'},
          {'registry': 'r.example.org', 'username': 'v', 'token': 'tok'},
        ],
      );
      expect(lokiBody('off'), isNull);
      expect(lokiBody('url', url: ' https://l.example.org '), {
        'url': 'https://l.example.org',
      });
      expect(validGithubOwner('example-org'), isTrue);
      expect(validGithubOwner('bad owner'), isFalse);
      expect(validServiceToken('tps_${'a' * 20}'), isTrue);
      expect(validServiceToken('tps_short'), isFalse);
    });

    test('tuzaklar, dış görünüm, saldırılar, kara kutu, kurtarma', () {
      final t = TrapsData(st.traps);
      expect(t.files.map((f) => f.status), ['armed', 'noatime', 'missing']);
      expect(t.files[1].lastTriggeredAt, isNotNull);
      expect(validDbTrapUser('app_backup'), isTrue);
      expect(validDbTrapUser('Ab'), isFalse);
      final e = ExposureData(st.exposure);
      expect(e.targets.first.expectedPorts, [22, 443]);
      expect(e.last!.findings.map((f) => f.rule).toSet(), isNotEmpty);
      expect(e.last!.targets.first.openPorts, [22, 443, 5432]);
      expect(e.last!.targets.last.scannedPorts, isFalse);
      expect(
        exposureBody(
          enabled: true,
          targets: e.targets,
          extraPorts: [8080],
          intervalDays: 7,
        )['targets'],
        [
          {
            'id': 'ip-203-0-113-10',
            'kind': 'ip',
            'value': '203.0.113.10',
            'expectedPorts': [22, 443],
          },
          {
            'id': 'domain-www-example-org',
            'kind': 'domain',
            'value': 'www.example.org',
          },
        ],
      );
      expect(
        exposureTargetId('domain', 'API.example.org', {
          'domain-api-example-org',
        }),
        'domain-api-example-org-2',
      );
      expect(validExposureValue('ip', '203.0.113.10'), isTrue);
      expect(validExposureValue('ip', '300.0.113.10'), isFalse);
      expect(validExposureValue('domain', '203.0.113.10'), isFalse);
      expect(validExposureValue('domain', 'www.example.org'), isTrue);
      expect(parsePortList('22, 443 22'), [22, 443]);
      expect(parsePortList('0'), isNull);
      expect(parsePortList('x'), isNull);
      final a = AttacksData({'configured': true, ...st.attacks});
      expect(a.offenders.first.paths.length, 3);
      expect(a.offenders.first.blockedUntil, isNotNull);
      expect(a.offenders.last.blockedUntil, isNull);
      expect(CloudflareConfig(st.cloudflare).hasBlockToken, isFalse);
      final v = BlackboxVerify({
        'ok': true,
        'count': 3,
        'head': 'x',
        'anchors': st.bbAnchors,
        'anchorMismatch': ['2026-11-12'],
      });
      expect(v.trustworthy, isFalse);
      expect(
        BlackboxVerify({'ok': false, 'brokenAt': 4, 'reason': 'hash'}).brokenAt,
        4,
      );
      expect(
        [for (final r in st.bbRecords) BlackboxRecord(r).summary],
        [
          'POST /v1/security/vulns/scan',
          'security.change',
          'recoveryCodeCreated',
        ],
      );
      expect(BlackboxStatus({'mode': 'off', 'head': null}).count, isNull);
      expect(LockdownTarget(st.lockdownTargets.first).hasToken, isTrue);
    });

    test('kurtarma kodu biçimi', () {
      expect(normalizeRecoveryInput('abcde fghjk-lmnpq'), 'ABCDEFGHJKLMNPQ');
      expect(recoveryCodeComplete('ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2'), isTrue);
      expect(recoveryCodeComplete('ABCDE-FGHJK'), isFalse);
      expect(
        formatRecoveryCode('abcdefghjklmnpqrstuvwxyz2'),
        'ABCDE-FGHJK-LMNPQ-RSTUV-WXYZ2',
      );
    });
  });

  group('metinler (TR ve EN)', () {
    for (final MapEntry(key: lang, value: l) in _langs.entries) {
      test('$lang: her durum, neden, kural ve bildirim metni var', () {
        for (final s in vulnStatuses) {
          expect(vulnStatusName(l, s), isNot(s), reason: s);
        }
        for (final e in [
          'nightOnly',
          'saveLimit',
          'noSource',
          'badOutput',
          'scanFailed',
          'saveFailed',
          'imageTooLarge',
          'agent.security.imageTooLarge',
          'knownHostsMissing',
          'failed',
          'notFound',
        ]) {
          expect(vulnErrorText(l, 'failed', e), isNot(e), reason: e);
        }
        expect(
          vulnErrorText(l, 'needsCredentials', 'ghcr.io'),
          contains('ghcr.io'),
        );
        expect(vulnErrorText(l, 'ok', null), isNull);
        for (final s in ['github', 'loki', 'local']) {
          expect(secretSourceName(l, s), isNot(s));
        }
        for (final s in trapFileStatuses) {
          expect(trapFileStatusName(l, s), isNot(s));
        }
        for (final r in exposureRules) {
          expect(
            exposureRuleTitle(l, r, 'www.example.org', {
              'port': 5432,
              'path': '/.env',
              'days': 5,
              'status': 200,
              'missing': 'a,b',
              'what': 'tls',
            }),
            isNot(startsWith(r)),
            reason: r,
          );
          expect(exposureRuleFix(l, r), isNotNull);
        }
        expect(
          exposureRuleTitle(l, 'exposure.tlsExpiry', 'x', {'days': -2}),
          isNotEmpty,
        );
        for (final r in [
          'sequence',
          'link',
          'hash',
          'truncated',
          'unreadable',
          null,
        ]) {
          expect(blackboxReasonText(l, r), isNotEmpty);
        }
        for (final k in ['audit', 'event', 'lockdown']) {
          expect(blackboxKindName(l, k), isNotEmpty);
        }
      });

      test(
        '$lang: her agent.security.* kodunun ve kara kutu kodunun metni var',
        () {
          for (final c in securityErrorCodes) {
            expect(
              securityErrorText(l, 'agent.security.$c'),
              isNot(contains('agent.security.$c')),
              reason: c,
            );
          }
          expect(
            securityErrorText(l, 'agent.blackbox.notLocal'),
            isNot(contains('agent.blackbox')),
          );
          expect(
            securityErrorText(l, 'agent.security.scannerOff', {
              'scanner': 'trivy',
            }),
            contains('Trivy'),
          );
          expect(
            securityErrorText(l, 'agent.security.unknownFuture'),
            contains('agent.security.unknownFuture'),
          );
        },
      );

      test('$lang: S-2…S-5 bildirimleri başlık ve gövde üretir', () {
        final cases = <String, Map<String, dynamic>>{
          'security.vulns': {
            'host': 'atlas',
            'image': 'example/web:1',
            'critical': 2,
            'high': 1,
            'agent': 'atlas',
          },
          'security.secretFound': {
            'host': 'atlas',
            'count': 2,
            'sources': 'github,loki',
            'where': 'example-org/site',
            'agent': 'atlas',
          },
          'blackbox.broken': {
            'host': 'atlas',
            'at': 12,
            'reason': 'hash',
            'agent': 'atlas',
          },
          'security.lockdown': {
            'host': 'atlas',
            'by': 'recovery',
            'agent': 'atlas',
          },
          'security.exposure': {
            'host': 'atlas',
            'count': 1,
            'targets': 'www.example.org',
            'agent': 'atlas',
          },
          'security.attack': {
            'host': 'atlas',
            'count': 3,
            'zones': 'example.org',
            'blocked': 1,
            'agent': 'atlas',
          },
        };
        for (final MapEntry(key: k, value: p) in cases.entries) {
          final t = noticeText(l, k, p);
          expect(t, isNotNull, reason: k);
          expect(t!.$1, isNotEmpty);
          expect(t.$2, isNotEmpty, reason: k);
        }
        expect(
          noticeText(l, 'security.lockdown', {'host': 'a', 'by': 'remote'})!.$2,
          isNot(
            noticeText(l, 'security.lockdown', {
              'host': 'a',
              'by': 'recovery',
            })!.$2,
          ),
        );
        final bodies = <String>{};
        for (final trap in [
          'token',
          'file',
          'fileMissing',
          'audit',
          'db',
          'test',
        ]) {
          final t = noticeText(l, 'security.trap', {
            'host': 'atlas',
            'trap': trap,
            'name': 'backup-token',
            'path': '/x',
            'from': '198.51.100.9',
            'who': 'alice',
            'how': 'cat',
            'object': '/home/alice/.env',
            'user': 'app_backup',
            'stream': 'db',
          })!;
          expect(t.$2, isNotEmpty, reason: trap);
          bodies.add(t.$2);
        }
        expect(bodies.length, 6);
        expect(
          noticeText(l, 'security.trap', {'host': 'a', 'trap': 'future'})!.$2,
          isNotEmpty,
        );
        expect(
          noticeText(l, 'security.vulns', {
            'host': 'atlas',
            'image': 'example/web:1',
            'critical': 2,
            'high': 1,
          })!.$1,
          contains('example/web:1'),
        );
      });
    }
  });

  group('bağlantılar ve bildirim yükü', () {
    test('derin bağlantılar', () {
      final hex = 'a' * 64;
      expect(
        routeForLink('tiphys://security/vulns/$hex'),
        '/security/vulns/$hex',
      );
      expect(routeForLink('tiphys://security/vulns/xyz'), isNull);
      for (final s in ['secrets', 'traps', 'blackbox', 'exposure', 'attacks']) {
        expect(routeForLink('tiphys://security/$s'), '/security/$s');
      }
      expect(routeForLink('tiphys://security'), '/security');
    });

    test('ajan ipucu: security.* ve blackbox.broken yükü ajan adını taşır', () {
      for (final k in [
        'security.trap',
        'security.vulns',
        'blackbox.broken',
        'security.attack',
      ]) {
        final p = jsonDecode(
          securityPayload(k, 'tiphys://security/traps', {'agent': 'atlas'})!,
        ) as Map;
        expect(p, {
          'link': 'tiphys://security/traps',
          'host': 'atlas',
        }, reason: k);
      }
      expect(
        securityPayload('security.trap', 'tiphys://security/traps', {}),
        isNull,
      );
      expect(
        routeForPayload(
          jsonEncode({'link': 'tiphys://security/traps', 'host': 'atlas'}),
        ),
        '/security/traps?host=atlas',
      );
    });

    test('acil kanal: tuzak, sır, kara kutu, kilitleme, dış görünüm; saldırı değil', () {
      expect(
        securityUrgentKeys,
        containsAll([
          'security.trap',
          'security.secretFound',
          'blackbox.broken',
          'security.lockdown',
          'security.exposure',
        ]),
      );
      expect(securityUrgentKeys.contains('security.attack'), isFalse);
    });
  });

  test('kilitleme çağrısı Authorization başlığı olmadan gider (belirteçsiz istemci)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <HttpRequest>[];
    String? body;
    server.listen((r) async {
      seen.add(r);
      body = await utf8.decoder.bind(r).join();
      r.response.headers.contentType = ContentType.json;
      r.response.write(jsonEncode({'ok': true, 'targets': []}));
      await r.response.close();
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      final anon = AgentClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: '',
      );
      await anon.request('POST', '/v1/security/lockdown', body: {'code': 'X'});
      anon.close();
      expect(seen.single.headers.value('authorization'), isNull);
      expect(seen.single.uri.path, '/v1/security/lockdown');
      expect(jsonDecode(body!), {'code': 'X'});
      final withToken = AgentClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'tph_x',
      );
      await withToken.request('GET', '/v1/health');
      withToken.close();
    }, _RealHttp());
    expect(seen.last.headers.value('authorization'), 'Bearer tph_x');
  });
}
