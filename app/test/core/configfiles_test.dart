// Config files and secrets (PLAN.md §13.3) and incident room I-2 parsing: staged edits → API ops, masked diff lines,
// reveal timer, conflict handling, preview details, deploys merging, texts and notification routing.
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/agent/agent_client.dart';
import 'package:tiphys/core/push/push_service.dart';
import 'package:tiphys/features/configfiles/config_reveal.dart';
import 'package:tiphys/features/configfiles/configfiles_data.dart';
import 'package:tiphys/features/configfiles/configfiles_texts.dart';
import 'package:tiphys/features/incidents/incident_texts.dart';
import 'package:tiphys/features/incidents/incidents_data.dart';
import 'package:tiphys/features/system/agent_providers.dart';
import 'package:tiphys/l10n/gen/app_localizations.dart';

import '../helpers/config_fixtures.dart';
import '../helpers/harness.dart' show exampleProfile;
import '../helpers/incident_fixtures.dart';

ConfigEntry entry(String key, {String? value, bool secret = false, bool duplicate = false}) => ConfigEntry({
      'key': key,
      'secret': secret,
      'masked': '••••${(value ?? 'x').length}',
      'length': (value ?? 'x').length,
      if (!secret) 'value': value ?? '',
      'duplicate': duplicate,
    });

class FakeTimers {
  final timers = <_FakeTimer>[];
  Timer call(Duration d, void Function() f) {
    final t = _FakeTimer(d, f);
    timers.add(t);
    return t;
  }

  /// Fires every timer due within [d] (all of them are created with the same lifetime in these tests).
  void elapse(Duration d) {
    for (final t in [...timers]) {
      if (!t.cancelled && !t.fired && t.duration <= d) t.fire();
    }
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this._f);
  final Duration duration;
  final void Function() _f;
  bool cancelled = false;
  bool fired = false;
  void fire() {
    fired = true;
    _f();
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => fired ? 1 : 0;
}

void main() {
  final tr = lookupAppLocalizations(const Locale('tr'));
  final en = lookupAppLocalizations(const Locale('en'));
  final argo = exampleProfile().host('argo')!;

  group('hazır değişiklikler → API işlemleri', () {
    final entries = [entry('DB_HOST', value: 'db'), entry('DB_PASSWORD', value: 'x' * 24, secret: true), entry('OLD', value: 'a'), entry('LOG', value: 'debug', duplicate: true), entry('LOG', value: 'info')];

    test('sıra: silme, yeniden adlandırma, değer (yeni adla), yeni anahtar', () {
      final e = ConfigEdits()
        ..add('NEW_KEY', 'v')
        ..setValue('DB_HOST', 'db2', entries[0])
        ..rename('DB_HOST', 'DATABASE_HOST')
        ..delete('OLD')
        ..setValue('DB_PASSWORD', 'fake-secret-A', entries[1]);
      expect(e.toOps(), [
        {'op': 'unset', 'key': 'OLD'},
        {'op': 'rename', 'key': 'DB_HOST', 'newKey': 'DATABASE_HOST'},
        {'op': 'set', 'key': 'DATABASE_HOST', 'value': 'db2'},
        {'op': 'set', 'key': 'DB_PASSWORD', 'value': 'fake-secret-A'},
        {'op': 'set', 'key': 'NEW_KEY', 'value': 'v'},
      ]);
      expect(e.count, 4, reason: 'DB_HOST (ad + değer) tek satır');
    });

    test('aynı değere dönmek, aynı ada dönmek ve geri alma hazır değişikliği siler', () {
      final e = ConfigEdits()
        ..setValue('DB_HOST', 'db2', entries[0])
        ..setValue('DB_HOST', 'db', entries[0])
        ..rename('OLD', 'X')
        ..rename('OLD', 'OLD')
        ..delete('DB_PASSWORD')
        ..undo('DB_PASSWORD');
      expect(e.isEmpty, isTrue);
      expect(e.toOps(), isEmpty);
    });

    test('silinen anahtarın değer ve ad değişikliği gönderilmez', () {
      final e = ConfigEdits()
        ..setValue('DB_HOST', 'db2', entries[0])
        ..rename('DB_HOST', 'H')
        ..delete('DB_HOST');
      expect(e.toOps(), [
        {'op': 'unset', 'key': 'DB_HOST'}
      ]);
    });

    test('yeni anahtarın adı ve değeri düzenlenir, sırası korunur; silinen ad yeniden kullanılabilir', () {
      final e = ConfigEdits()
        ..add('A', '1')
        ..add('B', '2')
        ..editAdded('A', 'A2', '3');
      expect(e.toOps(), [
        {'op': 'set', 'key': 'A2', 'value': '3'},
        {'op': 'set', 'key': 'B', 'value': '2'},
      ]);
      expect(e.nameTaken('OLD', entries), isTrue);
      e.delete('OLD');
      expect(e.nameTaken('OLD', entries), isFalse);
      expect(e.nameTaken('A2', entries), isTrue);
      expect(e.nameTaken('DB_HOST', entries, except: 'DB_HOST'), isFalse);
      e.rename('DB_HOST', 'Z');
      expect(e.nameTaken('Z', entries), isTrue, reason: 'başka satırın yeni adı');
    });

    test('satırlar: durumlar, sır değeri gösterilmez, tekrar eden satır düzenlenmez', () {
      final e = ConfigEdits()
        ..setValue('DB_HOST', 'db2', entries[0])
        ..setValue('DB_PASSWORD', 'fake-secret-A', entries[1])
        ..delete('OLD')
        ..add('N', 'abc');
      final rows = e.rows(entries);
      expect([for (final r in rows) (r.key, r.state)], [
        ('DB_HOST', EditState.changed),
        ('DB_PASSWORD', EditState.changed),
        ('OLD', EditState.deleted),
        ('LOG', EditState.none),
        ('LOG', EditState.none),
        ('N', EditState.added),
      ]);
      expect(rows[0].newValue, 'db2');
      expect(rows[1].newValue, isNull, reason: 'sır: yalnız uzunluk');
      expect(rows[1].newLength, 13);
      expect(rows[5].newLength, 3);
    });

    test('yeniden yükleme sonrası: anahtarı kalmayan hazır değişiklikler atılır', () {
      final e = ConfigEdits()
        ..setValue('DB_HOST', 'db2', entries[0])
        ..delete('OLD')
        ..rename('GONE', 'G2')
        ..add('DB_PASSWORD', 'v');
      final dropped = e.reconcile(entries);
      expect(dropped, 2, reason: 'GONE yok, DB_PASSWORD artık var');
      expect(e.toOps(), [
        {'op': 'unset', 'key': 'OLD'},
        {'op': 'set', 'key': 'DB_HOST', 'value': 'db2'},
      ]);
    });

    test('anahtar sözdizimi', () {
      expect(validConfigKey('DB_HOST'), isTrue);
      expect(validConfigKey('a.b'), isTrue);
      expect(validConfigKey('1A'), isFalse);
      expect(validConfigKey('A B'), isFalse);
      expect(validConfigKey(''), isFalse);
    });
  });

  group('maskeli satır farkı', () {
    ConfigChange change(Map<String, dynamic> j) => ConfigChange(j);
    String render(ConfigChange c) => [for (final l in changeDiff(c)) '${l.added ? '+' : '-'} ${l.text}'].join('\n');

    test('sır değerleri maskelenir, sır olmayanlar gösterilir', () {
      final secret = change({'key': 'DB_PASSWORD', 'change': 'changed', 'secret': true, 'before': {'length': 32}, 'after': {'length': 40}});
      expect(render(secret), '- DB_PASSWORD=••••32\n+ DB_PASSWORD=••••40');
      expect(secretLengthChange(secret), (32, 40));
      final plain = change({'key': 'WORKERS', 'change': 'changed', 'secret': false, 'before': {'length': 1, 'value': '4'}, 'after': {'length': 1, 'value': '8'}});
      expect(render(plain), '- WORKERS=4\n+ WORKERS=8');
      expect(secretLengthChange(plain), isNull);
    });

    test('eklenen, silinen, yeniden adlandırılan ve çıplak KEY', () {
      expect(render(change({'key': 'A', 'change': 'added', 'secret': false, 'after': {'length': 1, 'value': 'x'}})), '+ A=x');
      expect(render(change({'key': 'A', 'change': 'removed', 'secret': true, 'before': {'length': 7}})), '- A=••••7');
      expect(render(change({'key': 'NEW', 'change': 'renamed', 'from': 'OLD', 'secret': true, 'before': {'length': 5}, 'after': {'length': 5}})), '- OLD=••••5\n+ NEW=••••5');
      expect(render(change({'key': 'TZ', 'change': 'changed', 'secret': false, 'before': {'length': 0, 'inherited': true}, 'after': {'length': 3, 'value': 'UTC'}})), '- TZ\n+ TZ=UTC');
    });

    test('hiçbir diff satırı sır değerini taşımaz (sahte sunucu önizlemesi)', () {
      final st = FakeConfigState();
      final f = st.files['argo']!.first;
      final ops = [
        {'op': 'set', 'key': 'DB_PASSWORD', 'value': 'EXAMPLE-NEW-SECRET-9999'},
        {'op': 'set', 'key': 'DB_HOST', 'value': 'db2'},
      ];
      final p = ConfigPreview(Map<String, dynamic>.from(fakeConfigRoute('argo', 'POST', '/v1/config-files/${f.fileId}/preview', {'baseHash': f.hash, 'ops': ops}, st) as Map), DateTime(2026, 11, 14, 14, 5));
      final all = [for (final c in p.changes) ...changeDiff(c).map((l) => l.text)].join('\n');
      expect(all, isNot(contains('EXAMPLE-NEW-SECRET')));
      expect(all, isNot(contains(fakeSecretValue)));
      expect(all, contains('DB_HOST=db2'));
      expect(all, contains('DB_PASSWORD=••••${'EXAMPLE-NEW-SECRET-9999'.length}'));
      expect(p.affected.single.services, ['web', 'worker']);
    });
  });

  group('gösterme zamanlayıcısı', () {
    test('30 sn sonra yeniden maskelenir; yeniden gösterilen eski zamanlayıcıdan etkilenmez', () {
      final timers = FakeTimers();
      var changes = 0;
      final r = RevealStore(onChanged: () => changes++, timer: timers.call);
      r.reveal({'A': 'fake-a', 'B': 'fake-b'});
      expect(r.isRevealed('A'), isTrue);
      expect(r.valueOf('B'), 'fake-b');
      expect(timers.timers.single.duration, const Duration(seconds: 30));
      r.reveal({'A': 'fake-a2'});
      expect(timers.timers, hasLength(2));
      timers.timers.first.fire();
      expect(r.isRevealed('A'), isTrue, reason: 'A yeniden gösterildi: eski sayaç dokunmaz');
      expect(r.isRevealed('B'), isFalse);
      timers.timers.last.fire();
      expect(r.isEmpty, isTrue);
      expect(changes, 4);
    });

    test('gizle ve temizle: bellekten silinir, sayaçlar iptal edilir', () {
      final timers = FakeTimers();
      final r = RevealStore(onChanged: () {}, timer: timers.call);
      r.reveal({'A': 'fake-a', 'B': 'fake-b'});
      r.hide('A');
      expect(r.valueOf('A'), isNull);
      r.clear();
      expect(r.isEmpty, isTrue);
      expect(r.valueOf('B'), isNull);
      expect(timers.timers.single.cancelled, isTrue);
      expect(revealLifetime, const Duration(seconds: 30));
    });
  });

  group('çakışma ve hata metinleri', () {
    test('çakışma ve dosya değişti yeniden yükleme ister; diğerleri istemez', () {
      expect(configNeedsReload('agent.configfiles.conflict'), isTrue);
      expect(configNeedsReload('agent.configfiles.fileChanged'), isTrue);
      expect(configNeedsReload('agent.preview.invalid'), isFalse);
      expect(configNeedsReload('agent.configfiles.noChange'), isFalse);
    });

    test('önizleme sahte sunucuda baseHash eskiyse 409 conflict', () {
      final st = FakeConfigState();
      final f = st.files['argo']!.first;
      expect(
        () => fakeConfigRoute('argo', 'POST', '/v1/config-files/${f.fileId}/preview', {'baseHash': 'old', 'ops': []}, st),
        throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.configfiles.conflict')),
      );
    });

    test('hata kodları iki dilde metne çevrilir, değer içermez', () {
      for (final code in [
        'agent.configfiles.notFound', 'agent.configfiles.notEditable', 'agent.configfiles.fileChanged', 'agent.configfiles.conflict', 'agent.configfiles.notText',
        'agent.configfiles.keyNotFound', 'agent.configfiles.keyExists', 'agent.configfiles.unterminatedQuote', 'agent.configfiles.noChange', 'agent.configfiles.tooLarge',
        'agent.configfiles.confirmRequired', 'agent.configfiles.restartUnavailable', 'agent.configfiles.nothingToRestart', 'agent.configfiles.restartRateLimited',
        'agent.configfiles.rateLimited', 'agent.configfiles.backupNotFound',
      ]) {
        final t = agentErrorText(tr, AgentError(code, const {'key': 'DB_HOST', 'line': 3, 'reason': 'badName', 'limit': 6, 'windowSeconds': 600}));
        expect(t, isNot(contains('agent.configfiles')), reason: code);
        expect(agentErrorText(en, AgentError(code, const {'key': 'DB_HOST', 'line': 3, 'reason': 'badName', 'limit': 6, 'windowSeconds': 600})), isNot(contains('agent.configfiles')), reason: code);
      }
      expect(agentErrorText(tr, const AgentError('agent.configfiles.keyExists', {'key': 'DB_HOST'})), contains('DB_HOST'));
      expect(agentErrorText(en, const AgentError('agent.configfiles.restartRateLimited', {'limit': 6, 'windowSeconds': 600})), contains('6 per 10 min'));
      expect(agentErrorText(tr, const AgentError('agent.configfiles.notEditable', {'reason': 'tooLarge'})), contains('256 KB'));
    });

    test('atlanan dosya nedenleri ve uyarılar', () {
      expect(skipReasonText(tr, 'badName'), contains('.env'));
      expect(skipReasonText(en, 'outsideRoot'), contains('leaves'));
      expect(configWarningText(en, 'worldReadable', '0644'), contains('0644'));
      expect(configIssueText(tr, ConfigIssue({'line': 4, 'reason': 'unterminatedQuote'})), contains('4'));
    });
  });

  group('dosya ve önizleme ayrıştırma', () {
    test('dosya: sır maskeli, yaş, çift satır, salt okunur (kapanmamış tırnak)', () {
      final st = FakeConfigState();
      final f = st.files['argo']!.first;
      final j = Map<String, dynamic>.from(fakeConfigRoute('argo', 'GET', '/v1/config-files/${f.fileId}', null, st) as Map);
      final d = ConfigFileDetail(argo, j);
      expect(d.readOnly, isFalse);
      final pw = d.entry('DB_PASSWORD')!;
      expect(pw.secret, isTrue);
      expect(pw.masked, '••••${fakeSecretValue.length}');
      expect(pw.value, isNull);
      expect(jsonEncode(j), isNot(contains(fakeSecretValue)), reason: 'okuma yanıtı sır değerini taşımaz');
      expect(d.entry('API_TOKEN')!.due, isTrue);
      expect(d.entry('DB_PASSWORD')!.ageDays, 12);
      expect(d.entry('LOG_LEVEL')!.value, 'info', reason: 'son satır geçerli');
      expect(d.entries.where((e) => e.duplicate), hasLength(1));
      final broken = ConfigFileDetail(argo, {...j, 'issues': [{'line': 7, 'reason': 'unterminatedQuote'}, {'line': 9, 'reason': 'syntax'}]});
      expect(broken.readOnly, isTrue);
      expect(broken.unterminatedQuote!.line, 7);
      expect(broken.otherIssues.single.line, 9);
    });

    test('liste: yığına göre gruplama (yığınsız en sonda)', () {
      final st = FakeConfigState();
      final list = ConfigHostFiles(argo, Map<String, dynamic>.from(fakeConfigRoute('argo', 'GET', '/v1/config-files', null, st) as Map));
      final g = groupFilesByStack(list.files);
      expect([for (final (s, f) in g) (s, f.length)], [('shop', 2), (null, 1)]);
      expect(list.skipped.map((s) => s.reason), ['badName', 'notOwner', 'outsideRoot']);
      expect(list.files.first.secrets, 3);
    });

    test('yeniden başlatma planı ve sonuç: servis başına durum, başarısızlıkta yedeğe dön', () {
      final st = FakeConfigState();
      final f = st.files['argo']!.first;
      final now = DateTime(2026, 11, 14, 14, 5);
      final p = ConfigPreview(Map<String, dynamic>.from(fakeConfigRoute('argo', 'POST', '/v1/config-files/${f.fileId}/preview', {'baseHash': f.hash, 'ops': [{'op': 'set', 'key': 'DB_HOST', 'value': 'db2'}], 'restart': 'affected'}, st) as Map), now);
      expect(p.restart, 'affected');
      expect(p.restartPlan.single.argv.take(3), ['docker', 'compose', '-f']);
      expect(p.restartPlan.single.services, ['web', 'worker']);
      st.recreateFails = true;
      final r = ConfigSaveResult(Map<String, dynamic>.from(fakeConfigRoute('argo', 'PUT', '/v1/config-files/${f.fileId}', {'previewToken': p.token, 'confirm': true, 'restart': 'affected'}, st) as Map));
      expect(r.recreate!.ok, isFalse);
      expect(r.recreate!.stage, 'postCheck');
      expect([for (final s in r.recreate!.services) (s.service, s.ok, s.state)], [('web', true, 'running/healthy'), ('worker', false, 'exited')]);
      expect(r.restoreBackupId, r.backupId);
    });

    test('belirteç yeniden başlatma seçimine bağlı: farklı seçim → agent.preview.invalid', () {
      final st = FakeConfigState();
      final f = st.files['argo']!.first;
      final base = {'baseHash': f.hash, 'ops': [{'op': 'set', 'key': 'DB_HOST', 'value': 'db2'}]};
      final p = fakeConfigRoute('argo', 'POST', '/v1/config-files/${f.fileId}/preview', base, st) as Map;
      expect(
        () => fakeConfigRoute('argo', 'PUT', '/v1/config-files/${f.fileId}', {'previewToken': p['previewToken'], 'confirm': true, 'restart': 'affected'}, st),
        throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.preview.invalid')),
      );
      st.affected = [];
      expect(
        () => fakeConfigRoute('argo', 'POST', '/v1/config-files/${f.fileId}/preview', {...base, 'restart': 'affected'}, st),
        throwsA(isA<AgentError>().having((e) => e.code, 'code', 'agent.configfiles.nothingToRestart')),
      );
    });

    test('bildirim ve olay metinleri, dosya bağlantısı', () {
      expect(noticeText(tr, 'secret.rotationDue', {'host': 'argo', 'file': 'shop/.env', 'keys': 'DB_PASSWORD,API_TOKEN', 'count': 2}), ('Yenilenmesi gereken sırlar · argo', 'shop/.env · DB_PASSWORD,API_TOKEN'));
      expect(noticeText(en, 'config.restartFailed', {'host': 'argo', 'file': 'shop/.env', 'services': 'worker', 'stage': 'postCheck', 'backupId': 'b1'}), ('Service restart failed · argo', 'shop/.env saved; failed: worker'));
      expect(noticeText(tr, 'secret.changedExternally', {'file': 'shop/.env', 'keys': 'API_TOKEN', 'count': 1})!.$1, contains('dışında'));
      expect(noticeText(en, 'config.saved', {'file': 'shop/.env', 'keys': 'A'})!.$1, 'Config file saved');
      final payload = configPayload('secret.rotationDue', {'host': 'argo (PC)'}, {'fileId': 'cf-aaaaaaaaaaaaaaaaaaaaaaaa'});
      expect(jsonDecode(payload!), {'link': 'tiphys://configfiles', 'host': 'argo (PC)', 'fileId': 'cf-aaaaaaaaaaaaaaaaaaaaaaaa'});
      expect(routeForPayload(payload), '/configfiles/file?host=argo+%28PC%29&id=cf-aaaaaaaaaaaaaaaaaaaaaaaa');
      expect(configPayload('docker.died', {'host': 'argo'}, {'fileId': 'cf-aaaaaaaaaaaaaaaaaaaaaaaa'}), isNull);
      expect(routeForPayload(jsonEncode({'link': 'tiphys://configfiles', 'host': 'argo', 'fileId': '../x'})), '/configfiles');
      expect(routeForLink('tiphys://configfiles'), '/configfiles');
    });
  });

  group('olay odası I-2', () {
    final now = DateTime(2026, 11, 14, 14, 5);

    test('geri alma önizlemesi: şimdiki/önceki imaj kısa kimlik + tarih + uyarı', () {
      final st = FakeIncidentState();
      final j = fakeIncidentRoute('argo', 'POST', '/v1/incidents/inc-aaaaaaaaaaaa/actions/c-dddddddddddd/preview', null, sampleIncidents(), st) as Map;
      final p = ActionPreview(Map<String, dynamic>.from(j), now);
      expect(p.rollback!.tag, 'tiphys-rollback/shop-web:prev');
      expect(p.rollback!.imageRef, 'registry.example.org/web:1.4.2');
      expect(p.rollback!.current.shortId, '9f8e7d6c5b4a');
      expect(p.rollback!.previous.shortId, '1a2b3c4d5e6f');
      expect(p.rollback!.current.created, isNotNull);
      expect(p.warnings, ['dbMigrationsNotReverted']);
      expect(previewWarningText(tr, 'dbMigrationsNotReverted'), contains('geri alınmaz'));
      expect(previewWarningText(en, 'dbMigrationsNotReverted'), contains('not rolled back'));
      expect(p.cleanup, isNull);
      expect(shortImageId('abc'), 'abc');
    });

    test('disk temizliği önizlemesi: seçenek başına tahmin, kullanılamayanlar nedenle', () {
      final st = FakeIncidentState();
      final j = fakeIncidentRoute('argo', 'POST', '/v1/incidents/inc-bbbbbbbbbbbb/actions/c-cccccccccccc/preview', null, sampleIncidents(), st) as Map;
      final p = ActionPreview(Map<String, dynamic>.from(j), now);
      final c = p.cleanup!;
      expect(c.options.map((o) => o.option), ['userJournal', 'systemJournal', 'builder', 'images', 'containers']);
      expect(c.selected.toSet(), {'builder', 'images', 'containers'});
      final journal = c.options.first;
      expect(journal.available, isFalse);
      expect(journal.reason, 'needsRoot');
      expect(cleanupReasonText(tr, journal.reason), contains('root'));
      expect(c.options[1].reclaimableBytes, isNull);
      expect(c.selectedBytes, 1288490189 + 671088640 + 83886080);
      expect(estimateTotal(c.options, {'builder'}), 1288490189);
      expect(estimateTotal(c.options, {'userJournal'}), isNull, reason: 'kullanılamayan seçenek sayılmaz');
      expect(estimateTotal(c.options, {}), isNull);
      expect(p.steps.map((s) => s.argv.first), everyElement('docker'));
    });

    test('kullanılamayan seçenek → 409 cleanupOptionUnavailable, metin seçenek adını taşır', () {
      expect(
        () => fakeIncidentRoute('argo', 'POST', '/v1/incidents/inc-bbbbbbbbbbbb/actions/c-cccccccccccc/preview', {'options': ['userJournal']}, sampleIncidents(), FakeIncidentState()),
        throwsA(isA<AgentError>().having((e) => e.params['option'], 'option', 'userJournal')),
      );
      expect(agentErrorText(tr, const AgentError('agent.incident.cleanupOptionUnavailable', {'option': 'userJournal'})), contains("Kullanıcı journal'ı"));
      expect(agentErrorText(en, const AgentError('agent.incident.cleanupOptionUnavailable', {'option': 'builder'})), contains('Build cache'));
    });

    test('eylem adları: rollback ve disk.cleanup', () {
      expect(incidentActionLabel(tr, 'compose.rollback', {'service': 'web'}), 'web servisini önceki imaja geri al');
      expect(incidentActionLabel(en, 'disk.cleanup', {'mount': '/'}), 'Free disk space on /');
      expect(incidentActionName(en, 'compose.rollback'), 'Rollback');
    });

    test('dağıtımlar: bağlam ve geçmiş birleşir, kopyalar atılır, yeniden eskiye', () {
      final detail = IncidentDetail(argo, sampleIncidents()['argo']!.first);
      expect(detail.deploys, hasLength(2));
      final hist = [for (final e in sampleDeploysHistory()) DeployRecord(e)];
      final merged = mergeDeploys(hist, detail.deploys);
      expect(merged, hasLength(3), reason: 'web:1.4.2 iki kaynakta da var');
      expect(merged.first.service, 'web');
      expect(merged.map((d) => d.at).toList(), [...merged.map((d) => d.at)]..sort((a, b) => b.compareTo(a)));
      expect(merged.first.changed, isTrue);
      expect(merged.first.rollbackTag, 'tiphys-rollback/shop-web:prev');
      expect(merged.where((d) => d.kind == 'seen'), hasLength(1));
      expect(detail.summary.stack, 'shop');
    });

    test('ayar değişiklikleri yalnız anahtar adı taşır', () {
      final detail = IncidentDetail(argo, sampleIncidents()['argo']!.first);
      final c = detail.configChanges;
      expect(c.first.keys, ['DB_PASSWORD', 'WORKERS']);
      expect(c.first.restored, isFalse);
      expect(c.last.restored, isTrue);
      expect(c.first.file, 'shop/.env');
    });
  });
}
