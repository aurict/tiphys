// Velour (YouTube Music desktop player) remote: data side. Everything goes through the agent's POST /v1/velour {op, …},
// which forwards to Velour's local control socket (protocol: velour docs/remote-control.md).
// Tracks keep the JSON they came with, so "play / queue / play next" send Velour exactly what it gave us.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent/agent_client.dart';
import '../../core/util/refresh.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import 'agent_providers.dart';

/// Ops that call YouTube Music: they can take longer than the client's default timeout.
const _slowOps = {'lyrics', 'search', 'suggest', 'page', 'more', 'home', 'library', 'liked', 'history', 'rate', 'add-to-playlist', 'create-playlist'};

Duration _timeoutFor(String op) => Duration(seconds: _slowOps.contains(op) ? 40 : 10);

/// Provider-side call (inside a FutureProvider).
Future<dynamic> velourGet(Ref ref, String hostId, Map<String, Object?> op) => withAgent(
      ref,
      hostId,
      (c) async => ((await c.request('POST', '/v1/velour', body: op, timeout: _timeoutFor('${op['op']}'))) as Map)['result'],
    );

/// Button-side call; returns the result (for controls: the new state).
Future<dynamic> velourCall(WidgetRef ref, String hostId, Map<String, Object?> op) async {
  final host = ref.read(profileProvider).host(hostId);
  if (host == null) throw const AgentError('agent.notConfigured');
  final c = await ref.read(agentClientFactoryProvider)(host);
  try {
    return ((await c.request('POST', '/v1/velour', body: op, timeout: _timeoutFor('${op['op']}'))) as Map)['result'];
  } finally {
    c.close();
  }
}

/// Error text, with Velour-specific hints first.
String velourErrorText(AppLocalizations l, Object e) => switch (e) {
      AgentError(code: 'agent.velour.unavailable') => l.velourUnavailable,
      AgentError(code: 'agent.velour.notSignedIn') => l.velourNotSignedIn,
      AgentError(code: 'agent.velour.timeout') => l.velourTimeout,
      AgentError(code: 'agent.velour.notFound') => l.velourNotFound,
      AgentError(code: 'agent.velour.failed' || 'agent.velour.busy' || 'agent.velour.badRequest' || 'agent.velour.unsupportedVersion' || 'agent.velour.tooLarge') =>
        l.velourFailed,
      _ => agentErrorText(l, e),
    };

class VLink {
  VLink(Map j)
      : name = '${j['name'] ?? ''}',
        browseId = j['browseId'] as String?;
  final String name;
  final String? browseId;
}

class VTrack {
  VTrack(Map j)
      : json = j.cast<String, dynamic>(),
        videoId = '${j['videoId']}',
        title = '${j['title'] ?? ''}',
        artists = [for (final a in (j['artists'] as List? ?? const []).cast<Map>()) VLink(a)],
        album = j['album'] == null ? null : VLink(j['album'] as Map),
        duration = (j['duration'] as num?)?.toInt(),
        thumbnail = j['thumbnail'] as String?,
        playable = j['playable'] != false,
        like = j['like'] as String?;

  /// As received (sent back unchanged).
  final Map<String, dynamic> json;
  final String videoId;
  final String title;
  final List<VLink> artists;
  final VLink? album;
  final int? duration;
  final String? thumbnail;
  final bool playable;

  /// like | dislike | indifferent | null
  final String? like;

  String get artistLine => artists.map((a) => a.name).where((n) => n.isNotEmpty).join(', ');
  bool get liked => like == 'like';
}

class VTarget {
  VTarget(Map j)
      : json = j.cast<String, dynamic>(),
        kind = '${j['kind']}',
        id = j['id'] as String?,
        params = j['params'] as String?,
        pageType = j['pageType'] as String?;
  final Map<String, dynamic> json;

  /// browse | watch
  final String kind;
  final String? id;
  final String? params;

  /// album | playlist | artist | channel | podcast | other (browse only)
  final String? pageType;
  bool get isWatch => kind == 'watch';
}

class VCard {
  VCard(Map j)
      : title = '${j['title'] ?? ''}',
        subtitle = '${j['subtitle'] ?? ''}',
        thumbnail = j['thumbnail'] as String?,
        target = VTarget(j['target'] as Map),
        round = j['round'] == true;
  final String title;
  final String subtitle;
  final String? thumbnail;
  final VTarget target;
  final bool round;
}

/// A track or a card.
class VItem {
  VItem(Map j)
      : track = j['kind'] == 'track' ? VTrack(j) : null,
        card = j['kind'] == 'card' ? VCard(j) : null;
  final VTrack? track;
  final VCard? card;
}

class VSection {
  VSection(Map j)
      : title = '${j['title'] ?? ''}',
        layout = '${j['layout'] ?? 'list'}',
        items = [for (final i in (j['items'] as List? ?? const []).cast<Map>()) if (i['kind'] == 'track' || i['kind'] == 'card') VItem(i)];
  VSection.of(this.title, this.layout, this.items);
  final String title;

  /// list | carousel | grid
  final String layout;
  final List<VItem> items;
  List<VTrack> get tracks => [for (final i in items) ?i.track];
}

class VHeader {
  VHeader(Map j)
      : title = '${j['title'] ?? ''}',
        subtitle = '${j['subtitle'] ?? ''}',
        secondSubtitle = '${j['secondSubtitle'] ?? ''}',
        thumbnail = j['thumbnail'] as String?,
        play = j['play'] == null ? null : VTarget(j['play'] as Map),
        radio = j['radio'] == null ? null : VTarget(j['radio'] as Map),
        round = j['round'] == true;
  final String title;
  final String subtitle;
  final String secondSubtitle;
  final String? thumbnail;
  final VTarget? play;
  final VTarget? radio;
  final bool round;
}

class VPage {
  VPage(Map j)
      : header = j['header'] == null ? null : VHeader(j['header'] as Map),
        sections = [for (final s in (j['sections'] as List? ?? const []).cast<Map>()) VSection(s)],
        continuation = j['continuation'] as String?;
  VPage.of(this.header, this.sections, this.continuation);
  final VHeader? header;
  final List<VSection> sections;
  final String? continuation;
  bool get isEmpty => sections.every((s) => s.items.isEmpty);

  /// The next part (from `more`) appended: list items join the last list section, other sections are added.
  VPage append(VPage more) {
    final out = [...sections];
    for (final s in more.sections) {
      final i = out.lastIndexWhere((x) => x.layout == s.layout);
      if (i >= 0 && (s.title.isEmpty || s.title == out[i].title)) {
        out[i] = VSection.of(out[i].title, out[i].layout, [...out[i].items, ...s.items]);
      } else {
        out.add(s);
      }
    }
    return VPage.of(header, out, more.continuation);
  }
}

class VState {
  VState(Map j, this.fetchedAt)
      : track = j['track'] == null ? null : VTrack(j['track'] as Map),
        index = (j['index'] as num?)?.toInt(),
        queueLength = (j['queueLength'] as num?)?.toInt() ?? 0,
        playing = j['playing'] == true,
        loading = j['loading'] == true,
        position = (j['position'] as num?)?.toDouble() ?? 0,
        duration = (j['duration'] as num?)?.toDouble() ?? 0,
        volume = (j['volume'] as num?)?.toDouble() ?? 0,
        muted = j['muted'] == true,
        shuffle = j['shuffle'] == true,
        repeat = '${j['repeat'] ?? 'off'}',
        signedIn = j['signedIn'] == true;
  final VTrack? track;
  final int? index;
  final int queueLength;
  final bool playing;
  final bool loading;
  final double position;
  final double duration;
  final double volume;
  final bool muted;
  final bool shuffle;

  /// off | all | one
  final String repeat;
  final bool signedIn;
  final DateTime fetchedAt;

  /// Length: mpv's, else the listed one.
  double get length => duration > 0 ? duration : (track?.duration ?? 0).toDouble();

  /// While playing, the time since the query is added (smooth progress between polls).
  double positionAt(DateTime now) {
    var p = position;
    if (playing) p += now.difference(fetchedAt).inMilliseconds / 1000;
    return length > 0 ? p.clamp(0, length).toDouble() : p;
  }

  /// Changes when the queue's content or position may have changed.
  String get queueKey => '${track?.videoId}|$index|$queueLength|$shuffle';
}

class VQueue {
  VQueue(Map j)
      : index = (j['index'] as num?)?.toInt(),
        tracks = [for (final t in (j['tracks'] as List? ?? const []).cast<Map>()) VTrack(t)],
        radio = j['radio'] == true;
  final int? index;
  final List<VTrack> tracks;
  final bool radio;
}

class VLyrics {
  VLyrics(Map j)
      : videoId = '${j['videoId']}',
        kind = '${j['kind']}',
        lines = [for (final l in (j['lines'] as List? ?? const []).cast<Map>()) ((l['time'] as num).toDouble(), '${l['text']}')],
        text = j['text'] as String?,
        source = j['source'] as String?;
  final String videoId;

  /// synced | plain | none
  final String kind;
  final List<(double, String)> lines;
  final String? text;
  final String? source;

  /// Index of the line being sung at `pos` (null before the first).
  int? activeLine(double pos) {
    int? at;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].$1 <= pos + 0.2) {
        at = i;
      } else {
        break;
      }
    }
    return at;
  }
}

/// Now playing; polled every 2 s while visible.
final velourStateProvider = FutureProvider.autoDispose.family<VState, String>((ref, hostId) async {
  autoRefresh(ref, const Duration(seconds: 2));
  final now = ref.read(clockProvider);
  final j = await velourGet(ref, hostId, {'op': 'state'});
  return VState(j as Map, now());
});

/// The queue; refetched when the song, position or length changes.
final velourQueueProvider = FutureProvider.autoDispose.family<VQueue, String>((ref, hostId) async {
  ref.watch(velourStateProvider(hostId).select((s) => s.value?.queueKey));
  return VQueue(await velourGet(ref, hostId, {'op': 'queue'}) as Map);
});

/// Lyrics of the current song (host, videoId).
final velourLyricsProvider = FutureProvider.autoDispose.family<VLyrics, (String, String)>((ref, key) async {
  return VLyrics(await velourGet(ref, key.$1, {'op': 'lyrics'}) as Map);
});

/// What a page shows: search results, an album/playlist/artist, a library tab, liked songs, history.
@immutable
class VSource {
  const VSource(this.op, [this.arg, this.params]);
  const VSource.search(String q) : this('search', q);
  const VSource.page(String id, [String? params]) : this('page', id, params);
  const VSource.library(String tab) : this('library', tab);
  final String op;
  final String? arg;
  final String? params;

  Map<String, Object?> get request => switch (op) {
        'search' => {'op': 'search', 'query': arg},
        'page' => {'op': 'page', 'id': arg, 'params': ?params},
        'library' => {'op': 'library', 'tab': arg},
        _ => {'op': op},
      };

  @override
  bool operator ==(Object other) => other is VSource && other.op == op && other.arg == arg && other.params == params;
  @override
  int get hashCode => Object.hash(op, arg, params);
}

final velourPageProvider = FutureProvider.autoDispose.family<VPage, (String, VSource)>((ref, key) async {
  return VPage(await velourGet(ref, key.$1, key.$2.request) as Map);
});

final velourSuggestProvider = FutureProvider.autoDispose.family<List<String>, (String, String)>((ref, key) async {
  final r = await velourGet(ref, key.$1, {'op': 'suggest', 'query': key.$2});
  return (r as List).map((e) => '$e').toList();
});

/// Your own playlists (for "Add to playlist").
final velourPlaylistsProvider = FutureProvider.autoDispose.family<List<(String, String)>, String>((ref, hostId) async {
  final r = await velourGet(ref, hostId, {'op': 'playlists'});
  return [for (final p in (r as List).cast<Map>()) ('${p['id']}', '${p['title']}')];
});
