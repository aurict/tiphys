// ignore_for_file: use_null_aware_elements
// Sample incident room data in the agent's response format (agent/src/incidents/types.ts). Times are relative to the
// harness clock (2026-11-14 14:05 local).
import 'package:tiphys/core/agent/agent_client.dart';

final _clock = DateTime(2026, 11, 14, 14, 5);
String _at(int minutesAgo) => _clock.subtract(Duration(minutes: minutesAgo)).toUtc().toIso8601String();

Map<String, dynamic> _tl(int ago, String type, {String? by, String? key, String? text, Map<String, dynamic>? data}) =>
    {'at': _at(ago), 'type': type, if (by != null) 'by': by, if (key != null) 'key': key, if (text != null) 'text': text, if (data != null) 'data': data};

Map<String, dynamic> _incident(
  String id, {
  required String status,
  required String kind,
  required String target,
  String severity = 'critical',
  int openedAgo = 15,
  int signals = 1,
  String? resolvedAgo,
  String? note,
  String? worked,
  String? by,
  List<Map<String, dynamic>> timeline = const [],
  List<Map<String, dynamic>> hints = const [],
  Map<String, dynamic>? context,
  bool test = false,
  String? stack,
  String? service,
}) =>
    {
      'id': id,
      'status': status,
      'severity': severity,
      'host': 'argo',
      'kind': kind,
      'target': target,
      'stack': stack,
      'service': service,
      'openedAt': _at(openedAgo),
      'updatedAt': _at(openedAgo - 1),
      'lastSignalAt': _at(openedAgo - 1),
      if (resolvedAgo != null) 'resolvedAt': _at(int.parse(resolvedAgo)),
      if (by != null) 'resolvedBy': by,
      if (note != null) 'resolutionNote': note,
      if (worked != null) 'workedAction': worked,
      'signalCount': signals,
      'parts': [],
      'signals': [],
      'timeline': timeline,
      'hints': hints,
      if (context != null) 'context': context,
      'test': test,
    };

List<String> _logLines() => [
      '2026-11-14T13:50:01Z web starting on :8080',
      '2026-11-14T13:50:03Z connected to db',
      '2026-11-14T13:51:10Z worker 3 allocating 2 GiB buffer',
      '2026-11-14T13:51:12Z fatal: out of memory while parsing /srv/uploads/very-long-file-name-that-keeps-going-and-going-and-going-and-going.csv',
      '2026-11-14T13:51:12Z <b>not markdown</b> [link](http://example.org) is shown as plain text',
      '2026-11-14T13:51:13Z exited with code 137',
    ];

Map<String, dynamic> _deploy(int minutesAgo, String service, String imageId, String ref, {String kind = 'changed', String? prev, String? tag}) => {
      'at': _at(minutesAgo),
      'kind': kind,
      'project': 'shop',
      'service': service,
      'container': 'shop-$service-1',
      'imageId': imageId,
      'imageRef': ref,
      'createdAt': _at(minutesAgo + 600),
      'prevImageId': prev,
      'prevImageRef': prev == null ? null : ref.replaceFirst(RegExp(r':[^:]+$'), ':1.4.1'),
      'rollbackTag': tag,
    };

/// GET /v1/incidents/deploys: the history of the incident's service (one older deploy the context doesn't have).
List<Map<String, dynamic>> sampleDeploysHistory() => [
      _deploy(35, 'web', 'sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0', 'registry.example.org/web:1.4.2', prev: 'sha256:1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809', tag: 'tiphys-rollback/shop-web:prev'),
      _deploy(4300, 'web', 'sha256:1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809', 'registry.example.org/web:1.4.1', prev: 'sha256:0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f'),
    ];

Map<String, dynamic> _context() => {
      'collectedAt': _at(14),
      'logs': {'source': 'docker', 'target': 'web', 'lines': _logLines(), 'truncated': false},
      'inspect': {
        'name': 'web',
        'image': 'registry.example.org/web:1.4.2',
        'imageId': 'sha256:abc',
        'created': _at(40),
        'startedAt': _at(15),
        'finishedAt': _at(14),
        'status': 'exited',
        'running': false,
        'exitCode': 137,
        'oomKilled': true,
        'restartCount': 4,
        'restartPolicy': 'unless-stopped',
        'health': null,
        'project': 'shop',
        'service': 'web',
      },
      'git': {
        'repo': '~/stack/shop',
        'log': [
          {'hash': 'a1b2c3d4e5f6', 'date': _at(120), 'subject': 'web: raise worker count to 8'},
          {'hash': '9f8e7d6c5b4a', 'date': _at(600), 'subject': 'Update compose image tag'},
        ],
        'status': [' M compose.yaml', '?? notes.txt'],
      },
      'events': [
        {'at': _at(16), 'key': 'docker.died', 'params': {'host': 'argo', 'container': 'web', 'code': 137}},
        {'at': _at(60), 'key': 'backup.ok', 'params': {'host': 'argo', 'name': 'Veritabanı'}},
      ],
      'deploys': [
        _deploy(35, 'web', 'sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a39281706f5e4d3c2b1a0', 'registry.example.org/web:1.4.2', prev: 'sha256:1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809', tag: 'tiphys-rollback/shop-web:prev'),
        _deploy(1900, 'worker', 'sha256:aaaa1111bbbb2222cccc3333dddd4444aaaa1111bbbb2222cccc3333dddd4444', 'registry.example.org/worker:2.0.0', kind: 'seen'),
      ],
      'configChanges': [
        {'at': _at(300), 'key': 'config.saved', 'file': 'shop/.env', 'keys': ['DB_PASSWORD', 'WORKERS']},
        {'at': _at(1200), 'key': 'config.restored', 'file': 'shop/api.env', 'keys': ['STRIPE_KEY']},
      ],
      'metrics': _metrics(),
      'similar': [
        {'id': 'inc-eeeeeeeeeeee', 'kind': 'docker.died', 'status': 'resolved', 'openedAt': _at(3000), 'resolvedAt': _at(2990), 'resolutionNote': 'Raised memory limit', 'workedAction': 'container.restart'},
        {'id': 'inc-ffffffffffff', 'kind': 'docker.oom', 'status': 'resolved', 'openedAt': _at(9000), 'resolvedAt': _at(8990), 'workedAction': null},
      ],
    };

/// Metrics ring excerpt (epoch-millisecond samples every 3 minutes, ±30 min around the opening): memory climbs to the
/// limit, CPU is spiky, the disk is flat.
Map<String, dynamic> _metrics() {
  final start = _clock.subtract(const Duration(minutes: 45)).millisecondsSinceEpoch;
  return {
    'host': [
      for (var i = 0; i < 16; i++)
        {
          't': start + i * 180000,
          'cpu': 20.0 + (i % 4) * 9,
          'load1': 0.8 + i * 0.1,
          'memPct': 40.0 + i * 3.5,
          'swapPct': i < 8 ? 0.0 : (i - 7) * 4.0,
          'disks': [
            {'mount': '/', 'pct': 71.0},
          ],
        },
    ],
    'container': {
      'name': 'web',
      'samples': [
        for (var i = 0; i < 8; i++) {'t': start + i * 360000, 'cpu': 5.0 + i * 8, 'memPct': 30.0 + i * 9, 'memBytes': (200 + i * 40) * 1048576},
      ],
    },
  };
}

/// A finished analysis result: three hypotheses (the last one has no evidence → unsupported), two suggested actions (one
/// of the agent's candidates, one that is not on offer any more), questions. The evidence ids point into [_context].
Map<String, dynamic> sampleAnalysisResult() => {
      'summary': 'The web container ran out of memory right after the 1.4.2 deploy and keeps restarting.',
      'hypotheses': [
        {'cause': 'The new image 1.4.2 raised memory use past the container limit (exit code 137).', 'confidence': 0.86, 'evidenceRefs': ['log:docker#4', 'inspect:container', 'deploy:1', 'metric:host.memPct'], 'unsupported': false},
        {'cause': 'The worker count was raised to 8 in a recent commit, so more buffers are allocated.', 'confidence': 0.52, 'evidenceRefs': ['git:9f8e7d6c5b4a', 'config:1', 'event:1'], 'unsupported': false},
        {'cause': 'A noisy neighbour on the host is starving the container.', 'confidence': 0.18, 'evidenceRefs': <String>[], 'unsupported': true},
      ],
      'suggestedActions': [
        {'candidateId': 'c-aaaaaaaaaaaa', 'kind': 'container.restart', 'why': 'Brings the service back while the limit is reviewed.'},
        {'candidateId': 'c-999999999999', 'kind': 'compose.rollback', 'why': 'Returns to the previous image.'},
      ],
      'questions': ['Was the memory limit changed in the 1.4.2 release notes?', 'Does the worker count of 8 fit the host?'],
      'dropped': {'actions': 0, 'refs': 0},
    };

/// `incident.analysis` in the given state. `done` carries [sampleAnalysisResult].
Map<String, dynamic> sampleAnalysis(String status, {String mode = 'remote', String? reason, String? errorCode, int requestedAgo = 3}) => {
      'status': status,
      'mode': mode,
      'by': 'device:phone',
      'requestedAt': _at(requestedAgo),
      if (status == 'done' || status == 'failed' || status == 'unavailable') 'finishedAt': _at(requestedAgo - 1),
      'jobId': 'aj-0123456789abcdef',
      if (status == 'done') 'result': sampleAnalysisResult(),
      if (errorCode != null) 'error': {'code': errorCode, 'params': <String, dynamic>{}},
      if (reason != null) 'reason': reason,
    };

/// Incidents per host id (argo, atlas); tests may mutate them.
Map<String, List<Map<String, dynamic>>> sampleIncidents() => {
      'argo': [
        _incident('inc-aaaaaaaaaaaa',
            status: 'open',
            kind: 'docker.died',
            target: 'web',
            stack: 'shop',
            service: 'web',
            openedAgo: 15,
            signals: 3,
            hints: [
              {'code': 'oom', 'params': {'exitCode': 137}, 'evidence': ['inspect', 'signals']},
              {'code': 'restartLoop', 'params': {'restartCount': 4}, 'evidence': ['inspect']},
              {'code': 'recentDeploy', 'params': {'created': _at(40), 'image': 'registry.example.org/web:1.4.2'}, 'evidence': ['inspect']},
            ],
            context: _context(),
            timeline: [
              _tl(15, 'opened', key: 'docker.died', by: 'agent'),
              _tl(14, 'signal', key: 'docker.restartLoop'),
              _tl(14, 'context', data: {'ok': true, 'logLines': 6}),
              _tl(5, 'note', by: 'device:phone', text: 'Looking at the memory limit.'),
            ]),
        _incident('inc-bbbbbbbbbbbb', status: 'acknowledged', kind: 'disk.full', target: '/', severity: 'warning', openedAgo: 90, signals: 2, timeline: [_tl(90, 'opened', key: 'disk.full', by: 'agent'), _tl(30, 'acknowledged', by: 'device:phone')]),
        _incident('inc-eeeeeeeeeeee',
            status: 'resolved',
            kind: 'docker.died',
            target: 'web',
            openedAgo: 3000,
            resolvedAgo: '2990',
            note: 'Raised memory limit',
            worked: 'container.restart',
            by: 'device:phone',
            signals: 2,
            context: {'collectedAt': _at(2999), 'similar': <Map<String, dynamic>>[]},
            timeline: [
              _tl(3000, 'opened', key: 'docker.died', by: 'agent'),
              _tl(2998, 'action', by: 'device:phone', data: {'action': 'container.restart', 'candidate': 'c-111111111111'}),
              _tl(2998, 'actionResult', data: {'action': 'container.restart', 'ok': true, 'code': 0}),
              _tl(2996, 'postCheck', data: {'action': 'container.restart', 'ok': true, 'state': 'running'}),
              _tl(2990, 'resolved', by: 'device:phone', text: 'Raised memory limit'),
            ]),
      ],
      'atlas': [
        _incident('inc-cccccccccccc', status: 'open', kind: 'uptime.down', target: 'blog.example.org', severity: 'warning', openedAgo: 7, signals: 1),
        _incident('inc-dddddddddddd', status: 'resolved', kind: 'docker.unhealthy', target: 'api', severity: 'warning', openedAgo: 1500, resolvedAgo: '1480', by: 'auto', signals: 2),
      ],
    };

Map<String, dynamic> incidentSummary(Map<String, dynamic> i) => {
      for (final k in ['id', 'status', 'severity', 'host', 'kind', 'target', 'openedAt', 'updatedAt', 'lastSignalAt', 'signalCount', 'test']) k: i[k],
      'stack': i['stack'],
      'service': i['service'],
      'resolvedAt': i['resolvedAt'],
      'resolutionNote': i['resolutionNote'],
      'workedAction': i['workedAction'],
      'fingerprints': <String>[],
    };

/// Action candidates of the first incident (container restart, compose recreate, and with [rollback] the rollback) and
/// of the disk incident (cleanup, only with [cleanup]).
List<Map<String, dynamic>> sampleCandidates({bool rollback = false}) => [
      {'id': 'c-aaaaaaaaaaaa', 'kind': 'container.restart', 'target': {'container': 'web'}, 'risk': 'low'},
      {'id': 'c-bbbbbbbbbbbb', 'kind': 'compose.recreate', 'target': {'stack': 'shop', 'service': 'web'}, 'risk': 'medium'},
      if (rollback) {'id': 'c-dddddddddddd', 'kind': 'compose.rollback', 'target': {'stack': 'shop', 'service': 'web'}, 'risk': 'medium'},
    ];

const _cleanupCandidate = {'id': 'c-cccccccccccc', 'kind': 'disk.cleanup', 'target': {'mount': '/'}, 'risk': 'low'};

/// Estimates of the disk.cleanup options (the user journal needs root on this fake host).
List<Map<String, dynamic>> sampleCleanupOptions() => [
      {'option': 'userJournal', 'available': false, 'reason': 'needsRoot', 'reclaimableBytes': 314572800, 'usageBytes': 629145600},
      {'option': 'systemJournal', 'available': false, 'reason': 'needsRoot', 'reclaimableBytes': null, 'usageBytes': null},
      {'option': 'builder', 'available': true, 'reclaimableBytes': 1288490189, 'usageBytes': 2147483648},
      {'option': 'images', 'available': true, 'reclaimableBytes': 671088640, 'usageBytes': 4294967296},
      {'option': 'containers', 'available': true, 'reclaimableBytes': 83886080, 'usageBytes': 125829120},
    ];

/// POST /v1/incidents/... routes of the fake agent. Returns null when the path isn't an incident route.
dynamic fakeIncidentRoute(String hostId, String method, String path, Object? body, Map<String, List<Map<String, dynamic>>> store, FakeIncidentState st) {
  if (!path.startsWith('/v1/incidents')) return null;
  final list = store[hostId] ?? [];
  if (path == '/v1/incidents/deploys' && method == 'GET') return {'deploys': sampleDeploysHistory()};
  if (path == '/v1/incidents' && method == 'GET') return {'incidents': [for (final i in list) incidentSummary(i)]};
  final m = RegExp(r'^/v1/incidents/(inc-[a-f0-9]{12})(?:/(\w+)(?:/(c-[a-f0-9]{12})/(\w+))?)?$').firstMatch(path);
  if (m == null) throw const AgentError('agent.route.notFound');
  final inc = list.where((i) => i['id'] == m.group(1)).firstOrNull;
  if (inc == null) throw const AgentError('agent.incident.notFound', {}, 404);
  final op = m.group(2);
  List tl() => inc['timeline'] as List;
  if (op == null) {
    // A queued/running analysis moves on with every read of the incident (the app polls).
    final a = inc['analysis'];
    if (a is Map && (a['status'] == 'queued' || a['status'] == 'running') && st.analysisSteps.isNotEmpty) {
      final next = st.analysisSteps.removeAt(0);
      inc['analysis'] = sampleAnalysis(next, reason: next == 'unavailable' ? 'unreachable' : null, errorCode: next == 'failed' ? 'agent.analysis.invalidOutput' : (next == 'unavailable' ? 'agent.incident.analysis.unreachable' : null));
      if (next == 'done' || next == 'failed' || next == 'unavailable') {
        tl().add({'at': _clock.toUtc().toIso8601String(), 'type': 'analysisResult', 'data': {'status': next, if (next == 'done') ...{'hypotheses': 3, 'actions': 2}}});
      }
    }
    return {'incident': inc, 'similar': (inc['context'] as Map?)?['similar'] ?? <Map<String, dynamic>>[]};
  }
  switch ((method, op)) {
    case ('POST', 'ack'):
      inc['status'] = 'acknowledged';
      tl().add({'at': _clock.toUtc().toIso8601String(), 'type': 'acknowledged', 'by': 'device:phone'});
      return {'incident': inc};
    case ('POST', 'resolve'):
      inc['status'] = 'resolved';
      inc['resolvedAt'] = _clock.toUtc().toIso8601String();
      inc['resolvedBy'] = 'device:phone';
      final note = (body as Map?)?['note'];
      if (note != null) inc['resolutionNote'] = note;
      tl().add({'at': _clock.toUtc().toIso8601String(), 'type': 'resolved', 'by': 'device:phone', if (note != null) 'text': note});
      return {'incident': inc};
    case ('POST', 'reopen'):
      inc['status'] = 'open';
      tl().add({'at': _clock.toUtc().toIso8601String(), 'type': 'reopened', 'by': 'device:phone'});
      return {'incident': inc};
    case ('POST', 'notes'):
      tl().add({'at': _clock.toUtc().toIso8601String(), 'type': 'note', 'by': 'device:phone', 'text': (body as Map)['text']});
      return {'incident': inc};
    case ('POST', 'analyze'):
      if (st.analyzeError != null) throw st.analyzeError!;
      final cur = inc['analysis'];
      if (cur is Map && (cur['status'] == 'queued' || cur['status'] == 'running')) return {'analysis': cur};
      inc['analysis'] = sampleAnalysis('queued', mode: 'local', requestedAgo: 0);
      tl().add({'at': _clock.toUtc().toIso8601String(), 'type': 'analysis', 'by': 'device:phone', 'data': {'status': 'queued', 'mode': 'local'}});
      return {'analysis': inc['analysis']};
    case ('GET', 'bundle'):
      if (st.bundleError != null) throw st.bundleError!;
      return {'text': st.bundleText, 'bytes': st.bundleText.length, 'evidenceCount': 12, 'truncated': st.bundleTruncated};
    case ('GET', 'actions'):
      return {
        'actions': inc['id'] == 'inc-aaaaaaaaaaaa'
            ? sampleCandidates(rollback: st.rollback)
            : (inc['id'] == 'inc-bbbbbbbbbbbb' && st.cleanup ? [_cleanupCandidate] : <Map<String, dynamic>>[]),
        'running': st.running,
      };
    case ('POST', 'actions'):
      final c = [...sampleCandidates(rollback: true), _cleanupCandidate].firstWhere((c) => c['id'] == m.group(3));
      if (m.group(4) == 'preview') {
        st.issued = 'tpv_${++st.tokens}';
        Map<String, dynamic>? details;
        List<Map<String, dynamic>>? steps;
        if (c['kind'] == 'compose.rollback') {
          details = {
            'rollback': {
              'tag': 'tiphys-rollback/shop-web:prev',
              'imageRef': 'registry.example.org/web:1.4.2',
              'current': {'imageId': 'sha256:9f8e7d6c5b4a39281706f5e4d3c2b1a0', 'created': _at(635)},
              'previous': {'imageId': 'sha256:1a2b3c4d5e6f708192a3b4c5d6e7f809', 'created': _at(4900)},
            },
            'warnings': ['dbMigrationsNotReverted'],
          };
          steps = [
            {'argv': ['docker', 'tag', 'sha256:1a2b3c4d5e6f708192a3b4c5d6e7f809', 'registry.example.org/web:1.4.2']},
            {'argv': ['docker', 'compose', '-f', '/home/user/stack/shop/compose.yaml', 'up', '-d', '--no-deps', '--pull', 'never', 'web'], 'cwd': '/home/user/stack/shop'},
          ];
        } else if (c['kind'] == 'disk.cleanup') {
          final all = sampleCleanupOptions();
          final wanted = (body as Map?)?['options'] as List?;
          final avail = [for (final o in all) if (o['available'] == true) o['option'] as String];
          final selected = wanted == null ? avail : [for (final w in wanted) '$w'];
          for (final w in selected) {
            if (!avail.contains(w)) throw AgentError('agent.incident.cleanupOptionUnavailable', {'option': w}, 409);
          }
          st.issuedOptions = [...selected]..sort();
          details = {'cleanup': {'options': all, 'selected': selected}};
          const argvOf = {
            'builder': ['docker', 'builder', 'prune', '-f'],
            'images': ['docker', 'image', 'prune', '-f'],
            'containers': ['docker', 'container', 'prune', '-f', '--filter', 'until=24h'],
          };
          steps = [for (final o in selected) {'argv': argvOf[o]}];
        }
        return {
          'candidate': c,
          if (details != null) 'details': details,
          'steps': steps ??
              (c['kind'] == 'container.restart'
              ? [
                  {'argv': ['docker', 'restart', 'web']}
                ]
              : [
                  {'argv': ['docker', 'compose', '-f', '/home/user/stack/shop/compose.yaml', 'up', '-d', '--no-deps', 'web'], 'cwd': '/home/user/stack/shop'}
                ]),
          'risk': c['risk'],
          'previewToken': st.issued,
          'expiresAt': _clock.add(st.previewTtl).toUtc().toIso8601String(),
        };
      }
      final b = body as Map;
      if (b['confirm'] != true) throw const AgentError('agent.incident.confirmRequired', {}, 400);
      if (b['previewToken'] != st.issued || st.issued == null) throw const AgentError('agent.preview.invalid', {}, 409);
      if (c['kind'] == 'disk.cleanup' && ([for (final o in (b['options'] as List? ?? const [])) '$o']..sort()).join(',') != st.issuedOptions.join(',')) {
        throw const AgentError('agent.preview.invalid', {}, 409);
      }
      st.issued = null;
      if (st.executeError != null) throw st.executeError!;
      return st.executeResult;
  }
  throw const AgentError('agent.route.notFound');
}

/// Mutable knobs of the fake incident routes (tests reset it).
class FakeIncidentState {
  /// Offer the rollback candidate on the first incident / the cleanup candidate on the disk incident.
  bool rollback = false;
  bool cleanup = false;
  List<String> issuedOptions = [];
  String? running;
  String? issued;
  int tokens = 0;
  Duration previewTtl = const Duration(seconds: 118);
  AgentError? executeError;
  Map<String, dynamic> executeResult = {'ok': true, 'code': 0};

  /// `incidents.analysis.mode` GET /v1/config reports; null leaves the section out (an old agent).
  String? analysisMode;

  /// Thrown by POST .../analyze (analysisOff, analysisRateLimited, …).
  AgentError? analyzeError;

  /// The states a queued/running analysis goes through, one per read of the incident (the last one stays).
  final analysisSteps = <String>[];

  /// GET .../bundle?redacted=1: the redacted text (or an error).
  String bundleText = '[incident bundle]\ncontainer web exited with code 137\npassword=[GİZLİ]';
  bool bundleTruncated = false;
  AgentError? bundleError;
}
