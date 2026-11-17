// Fake agent for the Telegram newsletter screens (atlas: /v1/telegram/*) and the PC's research section
// (/v1/research/*, /v1/service-tokens). Sample data in the agent's real response format; nothing leaves the test.
import 'package:tiphys/core/agent/agent_client.dart';

import 'harness.dart';

class FakeTelegramAgent extends FakeAgent {
  FakeTelegramAgent(super.hostId);

  /// (host, method, path, body) of every telegram/research/service-token/config request.
  static final calls = <(String, String, String, Object?)>[];

  static Map<String, dynamic> status = sampleTgStatus();
  static List<Map<String, dynamic>> recipients = sampleRecipients();
  static List<Map<String, dynamic>> feeds = sampleFeeds();
  static List<Map<String, dynamic>> invites = sampleInvites();
  static Map<String, Map<String, dynamic>> issues = sampleIssues();
  static List<Map<String, dynamic>> tokens = sampleServiceTokens();
  static List<Map<String, dynamic>> jobs = sampleJobs();

  /// atlas's wake targets (GET /v1/config).
  static List<Map<String, dynamic>> wakeTargets = [
    {'hostId': 'argo', 'mac': '02:00:00:00:00:01', 'broadcast': '255.255.255.255', 'port': 9},
  ];

  /// Error to throw for PATCH /v1/config (connect-flow failure test).
  static AgentError? patchConfigError;

  static void reset() {
    calls.clear();
    status = sampleTgStatus();
    recipients = sampleRecipients();
    feeds = sampleFeeds();
    invites = sampleInvites();
    issues = sampleIssues();
    tokens = sampleServiceTokens();
    jobs = sampleJobs();
    patchConfigError = null;
  }

  Map<String, dynamic> _summary(Map<String, dynamic> i) {
    final d = (i['deliveries'] as List).cast<Map>();
    return {
      ...i,
      'itemCount': (i['items'] as List).length,
      'partCount': (i['renderedParts'] as List).length,
      'deliveryCounts': {
        'sent': d.where((x) => x['status'] == 'sent' && x['test'] != true).length,
        'failed': d.where((x) => x['status'] != 'sent' && x['test'] != true).length,
        'tests': d.where((x) => x['test'] == true).length,
      },
    }
      ..remove('items')
      ..remove('renderedParts')
      ..remove('deliveries');
  }

  @override
  Future<dynamic> request(String method, String path, {Object? body, Map<String, String>? query, Duration? timeout, Map<String, String>? headers}) async {
    final tg = path.startsWith('/v1/telegram/'), rs = path.startsWith('/v1/research/'), st = path.startsWith('/v1/service-tokens'), cfg = path == '/v1/config';
    if (!(tg || rs || st || cfg)) return super.request(method, path, body: body, query: query, timeout: timeout, headers: headers);
    calls.add((hostId, method, path, body));
    if (cfg) {
      if (method == 'PATCH') {
        if (patchConfigError != null) throw patchConfigError!;
        return {'config': {'name': hostId, 'devices': [], 'push': {}}, 'restartRequired': false};
      }
      final base = Map<String, dynamic>.from(await super.request(method, path, body: body, query: query) as Map);
      return {...base, 'wake': {'targets': wakeTargets}};
    }
    if (st) {
      if (method == 'GET') return {'tokens': tokens};
      if (method == 'POST') {
        final t = {'id': 'st_atlas-2b7e', 'name': (body as Map)['name'], 'scopes': body['scopes'], 'createdAt': '2026-11-14T13:05:00Z'};
        tokens = [...tokens, t];
        return {'token': 'tps_fake_never_shown', 'serviceToken': t};
      }
      tokens = [for (final t in tokens) if (!path.endsWith('/${t['id']}')) t];
      return {'ok': true};
    }
    if (rs) {
      if (method == 'GET') return {'jobs': jobs};
      return {'cancelled': true, 'job': {}};
    }
    final seg = path.substring('/v1/telegram/'.length).split('/');
    switch ((method, seg)) {
      case ('GET', ['status']):
        return status;
      case ('PUT', ['bot']):
        status = {...status, 'bot': {'configured': true, 'username': 'tiphysbot', 'id': 1}};
        return {'bot': {'username': 'tiphysbot', 'id': 1}};
      case ('DELETE', ['bot']):
        status = {...status, 'bot': {'configured': false, 'username': null, 'id': null}};
        return {'ok': true};
      case ('GET', ['recipients']):
        return {'recipients': recipients};
      case ('PATCH', ['recipients', final id]):
        recipients = [for (final r in recipients) r['id'] == id ? {...r, ...(body as Map).cast<String, dynamic>()} : r];
        return {'recipient': recipients.firstWhere((r) => r['id'] == id)};
      case ('DELETE', ['recipients', final id]):
        recipients = [for (final r in recipients) if (r['id'] != id) r];
        return {'ok': true};
      case ('POST', ['recipients', _, 'test']):
        return {'ok': true, 'messageIds': [91]};
      case ('GET', ['recipients', final id, 'deliveries']):
        return {
          'deliveries': [
            for (final i in issues.values)
              for (final d in (i['deliveries'] as List).cast<Map<String, dynamic>>())
                if (d['recipientId'] == id) {...d, 'issueId': i['id'], 'feedId': i['feedId']},
          ],
        };
      case ('GET', ['invites']):
        return {'invites': invites};
      case ('POST', ['invites']):
        final inv = {
          'id': 'inv_new',
          'label': (body as Map)['label'],
          'feedIds': body['feedIds'] ?? [],
          'createdAt': '2026-11-14T13:05:00Z',
          'expiresAt': '2026-11-15T13:05:00Z',
          'status': 'pending',
          'recipientId': null,
          'code': 'k3Jd9QpX2mZ7',
          'link': 'https://t.me/tiphysbot?start=k3Jd9QpX2mZ7',
        };
        invites = [...invites, inv];
        return {'invite': inv};
      case ('DELETE', ['invites', final id]):
        invites = [for (final i in invites) i['id'] == id ? {...i, 'status': 'revoked', 'code': null, 'link': null} : i];
        return {'invite': invites.firstWhere((i) => i['id'] == id)};
      case ('GET', ['templates']):
        return {'templates': sampleTemplates()};
      case ('GET', ['feeds']):
        return {'feeds': feeds};
      case ('POST', ['feeds']):
        final f = {...(body as Map).cast<String, dynamic>(), 'id': 'f_new', 'createdAt': '2026-11-14T13:05:00Z', 'running': false, 'nextRun': null, 'recipientIds': <String>[]};
        feeds = [...feeds, f];
        return {'feed': f};
      case ('PUT', ['feeds', final id]):
        feeds = [for (final f in feeds) f['id'] == id ? {...f, ...(body as Map).cast<String, dynamic>()} : f];
        return {'feed': feeds.firstWhere((f) => f['id'] == id)};
      case ('DELETE', ['feeds', final id]):
        feeds = [for (final f in feeds) if (f['id'] != id) f];
        return {'ok': true};
      case ('POST', ['feeds', final id, final kind]):
        final issue = {...issues['i_daily_preview']!, 'id': 'i_new', 'feedId': id, 'kind': kind == 'preview' ? 'preview' : 'manual', 'status': 'researching', 'items': [], 'renderedParts': [], 'deliveries': []};
        issues['i_new'] = issue;
        return {'issue': _summary(issue)};
      case ('GET', ['issues']):
        final fid = query?['feedId'];
        final list = issues.values.where((i) => fid == null || i['feedId'] == fid).toList()..sort((a, b) => '${b['createdAt']}'.compareTo('${a['createdAt']}'));
        return {'issues': [for (final i in list) _summary(i)]};
      case ('GET', ['issues', final id]):
        final i = issues[id];
        if (i == null) throw const AgentError('agent.telegram.issue.notFound', {}, 404);
        return {'issue': i};
      case ('POST', ['issues', final id, final action]) when action == 'approve' || action == 'reject':
        issues[id] = {...issues[id]!, 'status': action == 'approve' ? 'sending' : 'rejected'};
        return {'issue': _summary(issues[id]!)};
      case ('POST', ['issues', _, 'test']):
        return {'delivery': {'recipientId': (body as Map)['recipientId'], 'status': 'sent', 'messageIds': [92], 'at': '2026-11-14T13:05:00Z', 'test': true}};
    }
    throw const AgentError('agent.route.notFound', {}, 404);
  }
}

Map<String, dynamic> sampleTgStatus({bool bot = true}) => {
      'bot': bot ? {'configured': true, 'username': 'tiphysbot', 'id': 1} : {'configured': false, 'username': null, 'id': null},
      'research': {'configured': true, 'url': 'https://argo.example.ts.net:7443', 'wakeHostId': 'argo', 'reachable': true},
      'pendingInvites': 1,
      'polling': true,
    };

List<Map<String, dynamic>> sampleRecipients() => [
      {
        'id': 'r_ayse', 'chatId': 1001, 'firstName': 'Ayşe', 'lastName': 'Yılmaz', 'username': 'ayse', 'addedAt': '2026-11-10T09:12:00Z', //
        'status': 'active', 'subscriptions': ['f_daily', 'f_weekly'],
      },
      {'id': 'r_mehmet', 'chatId': 1002, 'firstName': 'Mehmet', 'addedAt': '2026-11-12T18:40:00Z', 'status': 'paused', 'statusAt': '2026-11-13T08:00:00Z', 'subscriptions': ['f_daily']},
    ];

Map<String, dynamic> _feed(Map<String, dynamic> input) => {
      'enabled': true,
      'language': 'tr',
      'maxSourcesPerItem': 3,
      'allowDomains': <String>[],
      'blockDomains': <String>[],
      'skipIfNothingNew': true,
      'approval': {'mode': 'firstN', 'n': 3},
      'deadlineMinutes': 30,
      ...input,
    };

List<Map<String, dynamic>> sampleTemplates() => [
      {
        'id': 'daily-tech-ai',
        'feed': _feed({
          'name': 'Günlük teknoloji ve yapay zekâ',
          'when': {'kind': 'daily', 'time': '08:00'},
          'topic': 'Son 24 saatin en önemli teknoloji ve yapay zekâ haberleri: yeni modeller ve ürünler, büyük şirket duyuruları, açık kaynak, güvenlik, düzenlemeler ve önemli araştırmalar.',
          'windowHours': 24,
          'minItems': 5,
          'maxItems': 8,
        }),
      },
      {
        'id': 'weekly-tech-ai',
        'feed': _feed({
          'name': 'Haftalık teknoloji ve yapay zekâ özeti',
          'when': {'kind': 'weekly', 'time': '09:00', 'days': [1]},
          'topic': 'Son 7 günün en önemli teknoloji ve yapay zekâ gelişmeleri.',
          'windowHours': 168,
          'minItems': 10,
          'maxItems': 12,
        }),
      },
    ];

List<Map<String, dynamic>> sampleFeeds() => [
      {
        ...(sampleTemplates()[0]['feed'] as Map<String, dynamic>),
        'id': 'f_daily', 'createdAt': '2026-11-10T08:00:00Z', 'anchorAt': '2026-11-10T08:00:00Z', 'lastSlotAt': '2026-11-14T07:00:00Z', //
        'approval': {'mode': 'firstN', 'n': 3, 'sentCount': 3}, 'running': false, 'nextRun': '2026-11-15T07:00:00Z', 'recipientIds': ['r_ayse', 'r_mehmet'],
      },
      {
        ...(sampleTemplates()[1]['feed'] as Map<String, dynamic>),
        'id': 'f_weekly', 'createdAt': '2026-11-10T08:00:00Z', 'anchorAt': '2026-11-10T08:00:00Z', 'lastSlotAt': '2026-11-10T08:00:00Z', //
        'approval': {'mode': 'ask', 'n': 3, 'sentCount': 1}, 'running': false, 'nextRun': '2026-11-16T08:00:00Z', 'recipientIds': ['r_ayse'],
      },
    ];

List<Map<String, dynamic>> sampleInvites() => [
      {
        'id': 'inv_1', 'label': 'Annem', 'feedIds': ['f_daily'], 'createdAt': '2026-11-14T12:00:00Z', 'expiresAt': '2026-11-15T12:00:00Z', //
        'status': 'pending', 'recipientId': null, 'code': 'Qm8xT2pL4vN1', 'link': 'https://t.me/tiphysbot?start=Qm8xT2pL4vN1',
      },
      {'id': 'inv_0', 'label': null, 'feedIds': ['f_daily'], 'createdAt': '2026-11-10T09:00:00Z', 'expiresAt': '2026-11-11T09:00:00Z', 'status': 'used', 'recipientId': 'r_ayse'},
    ];

/// Six validated items with 1–3 sources each (the agent's RenderItem shape).
List<Map<String, dynamic>> sampleItems() => [
      {
        'headline': 'Açık ağırlıklı yeni dil modeli yayımlandı',
        'summary': 'Model 70 milyar parametreli; kodlama ve Türkçe testlerinde önceki sürümü geçiyor. Lisans ticari kullanıma açık.',
        'sources': [
          {'title': 'Duyuru', 'url': 'https://example-ai.org/blog/model-release'},
          {'title': 'Haber', 'url': 'https://www.technews.example.com/2026/11/14/model'},
        ],
      },
      {
        'headline': 'AB yapay zekâ yasasında yeni uygulama rehberi',
        'summary': 'Komisyon genel amaçlı modeller için şeffaflık şablonunu yayımladı; şirketlere 6 ay uyum süresi tanındı.',
        'sources': [
          {'title': 'Komisyon', 'url': 'https://commission.example.eu/press/ai-guidance'},
        ],
      },
      {
        'headline': 'Tarayıcıda kritik güvenlik açığı kapatıldı',
        'summary': 'Uzaktan kod çalıştırmaya izin veren açık için acil güncelleme çıktı; otomatik güncelleme açık değilse elle güncellenmeli.',
        'sources': [
          {'title': 'Güvenlik bülteni', 'url': 'https://security.example.org/advisories/2026-311'},
          {'title': 'Haber', 'url': 'https://news.example.net/browser-patch'},
          {'title': 'Analiz', 'url': 'https://blog.example.dev/rce-analysis'},
        ],
      },
      {
        'headline': 'Yarı iletken üreticisi yeni fabrika planını açıkladı',
        'summary': '2 nm üretim için 20 milyar dolarlık yatırım; üretimin 2028\'de başlaması bekleniyor.',
        'sources': [
          {'title': 'Şirket', 'url': 'https://chips.example.com/news/fab'},
        ],
      },
      {
        'headline': 'Açık kaynak derleyici projesine büyük katkı',
        'summary': 'Yeni optimizasyon geçişi derleme sürelerini ortalama %18 kısaltıyor; sürüm notları yayında.',
        'sources': [
          {'title': 'Sürüm notları', 'url': 'https://compiler.example.org/releases/19'},
        ],
      },
      {
        'headline': 'Robotik araştırmasında <b>etiket</b> içeren başlık & işaret',
        'summary': 'Kaçış denetimi: bu madde HTML karakterleri içeriyor ve düz metin olarak görünmeli.',
        'sources': [
          {'title': 'Makale', 'url': 'https://arxiv.example.org/abs/2611.01234'},
        ],
      },
    ];

String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// Same layout as the agent's render.ts (title, numbered items, "Kaynak:" links, footer).
List<String> renderSample(String feedName, List<Map<String, dynamic>> items, {String emoji = '📰'}) {
  final blocks = [
    for (final (i, it) in items.indexed)
      '${i + 1}. <b>${_esc('${it['headline']}')}</b>\n${_esc('${it['summary']}')}\nKaynak: ${[
        for (final s in (it['sources'] as List).cast<Map>()) '<a href="${_esc('${s['url']}')}">${Uri.parse('${s['url']}').host.replaceFirst('www.', '')}</a>',
      ].join(' · ')}',
  ];
  return ['$emoji <b>${_esc(feedName)}</b> · 14 Kasım 2026\n\n${blocks.join('\n\n')}\n\n<i>Tiphys · Gemini 4 Argon + Claude · 08:00</i>'];
}

Map<String, Map<String, dynamic>> sampleIssues() {
  final items = sampleItems();
  return {
    'i_daily_1114': {
      'id': 'i_daily_1114', 'feedId': 'f_daily', 'kind': 'scheduled', 'createdAt': '2026-11-14T07:00:00Z', 'slotAt': '2026-11-14T07:00:00Z', //
      'deadlineAt': '2026-11-14T07:30:00Z', 'status': 'sent', 'finishedAt': '2026-11-14T07:06:00Z',
      'models': {'research': 'gemini-4-argon-high', 'editor': 'claude-sonnet'},
      'stats': {'received': 8, 'kept': 6, 'droppedItems': 2, 'droppedSources': 3},
      'items': items,
      'renderedParts': renderSample('Günlük teknoloji ve yapay zekâ', items),
      'deliveries': [
        {'recipientId': 'r_ayse', 'status': 'sent', 'messageIds': [51], 'at': '2026-11-14T07:06:00Z'},
        {'recipientId': 'r_mehmet', 'status': 'sent', 'messageIds': [52], 'at': '2026-11-14T07:06:01Z'},
      ],
    },
    'i_weekly_1110': {
      'id': 'i_weekly_1110', 'feedId': 'f_weekly', 'kind': 'scheduled', 'createdAt': '2026-11-14T08:00:00Z', 'slotAt': '2026-11-14T08:00:00Z', //
      'deadlineAt': '2026-11-14T08:30:00Z', 'expiresAt': '2026-11-14T15:30:00Z', 'status': 'awaiting_approval', 'finishedAt': '2026-11-14T08:09:00Z',
      'models': {'research': 'gemini-4-argon-high', 'editor': 'claude-sonnet'},
      'stats': {'received': 6, 'kept': 5, 'droppedItems': 1, 'droppedSources': 0},
      'items': items.take(5).toList(),
      'renderedParts': renderSample('Haftalık teknoloji ve yapay zekâ özeti', items.take(5).toList(), emoji: '🗞️'),
      'deliveries': <Map<String, dynamic>>[],
    },
    'i_daily_preview': {
      'id': 'i_daily_preview', 'feedId': 'f_daily', 'kind': 'preview', 'createdAt': '2026-11-13T19:00:00Z', 'deadlineAt': '2026-11-13T19:30:00Z', //
      'status': 'failed', 'error': 'agent.telegram.research.unreachable', 'finishedAt': '2026-11-13T19:30:00Z',
      'items': <Map<String, dynamic>>[], 'renderedParts': <String>[], 'deliveries': <Map<String, dynamic>>[],
    },
  };
}

List<Map<String, dynamic>> sampleServiceTokens() => [
      {'id': 'st_lyra-1a2b', 'name': 'lyra', 'scopes': ['research'], 'createdAt': '2026-11-10T08:00:00Z', 'lastUsedAt': '2026-11-14T07:00:00Z'},
    ];

List<Map<String, dynamic>> sampleJobs() => [
      {
        'id': 'rj-00000000000000a3', 'status': 'running', 'createdAt': '2026-11-14T13:00:00Z', 'startedAt': '2026-11-14T13:00:01Z', 'finishedAt': null, 'error': null, //
        'topic': 'Son 7 günün en önemli teknoloji ve yapay zekâ gelişmeleri.', 'editor': true, 'requestedBy': 'service:st_lyra-1a2b', 'itemCount': null, 'sourceCount': null, 'timings': null,
      },
      {
        'id': 'rj-00000000000000a2', 'status': 'done', 'createdAt': '2026-11-14T07:00:00Z', 'startedAt': '2026-11-14T07:00:01Z', 'finishedAt': '2026-11-14T07:05:31Z', 'error': null, //
        'topic': 'Son 24 saatin en önemli teknoloji ve yapay zekâ haberleri', 'editor': true, 'requestedBy': 'service:st_lyra-1a2b', 'itemCount': 8, 'sourceCount': 14,
        'timings': {'researchSec': 260, 'editorSec': 70},
      },
      {
        'id': 'rj-00000000000000a1', 'status': 'failed', 'createdAt': '2026-11-13T19:00:00Z', 'startedAt': '2026-11-13T19:00:01Z', 'finishedAt': '2026-11-13T19:00:09Z', //
        'error': {'code': 'agent.research.toolFailed', 'params': {'tool': 'agy', 'exitCode': 1}},
        'topic': 'Son 24 saatin en önemli teknoloji ve yapay zekâ haberleri', 'editor': true, 'requestedBy': 'device:redmi', 'itemCount': null, 'sourceCount': null, 'timings': null,
      },
    ];
