// Velour on the phone itself (Android): a media notification/lock-screen session that mirrors the live state and sends
// its buttons to the PC, and the volume buttons while the remote screen is open. Nothing plays on the phone.
// - Starts when the remote opens (if "Controls on the phone" is on) and keeps the live state alive while the app process
//   lives; swiping the paused notification away, or turning the switch off, ends it. The switch is per app run.
// - Other platforms (and tests): nothing happens.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tiphys_native/tiphys_native.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import 'velour_data.dart';

class VelourMediaState {
  const VelourMediaState({this.enabled = true, this.hostId});
  final bool enabled;

  /// The host whose Velour is on the notification.
  final String? hostId;
}

class VelourMedia extends Notifier<VelourMediaState> {
  /// Overridable in tests (the real platform check is false there anyway).
  static bool supported = Platform.isAndroid;

  ProviderSubscription<AsyncValue<VState>>? _live;
  String? _screenHost;
  String _lastKey = '';
  AppLocalizations? _l;
  final _volume = StreamController<int>.broadcast();

  /// The new Velour volume after each volume-button press (the screen shows it).
  Stream<int> get volumeKeys => _volume.stream;

  @override
  VelourMediaState build() {
    ref.onDispose(() {
      _detach(dispose: true);
      unawaited(_volume.close());
    });
    if (supported) {
      TiphysNative.listen();
      TiphysNative.onVelourMedia = _onMedia;
      TiphysNative.onVolumeKey = _onVolumeKey;
    }
    return const VelourMediaState();
  }

  void screenOpened(String hostId, AppLocalizations l) {
    _screenHost = hostId;
    _l = l;
    if (!supported) return;
    unawaited(_native(() => TiphysNative.setVolumeKeyCapture(true)));
    if (state.enabled) _attach(hostId);
  }

  void screenClosed(String hostId) {
    if (_screenHost == hostId) _screenHost = null;
    if (supported) unawaited(_native(() => TiphysNative.setVolumeKeyCapture(false)));
  }

  void setEnabled(bool on) {
    state = VelourMediaState(enabled: on, hostId: on ? state.hostId : null);
    if (!on) {
      _detach();
    } else if (_screenHost != null && supported) {
      _attach(_screenHost!);
    }
  }

  void _attach(String hostId) {
    if (state.hostId == hostId && _live != null) return;
    _detach();
    state = VelourMediaState(enabled: state.enabled, hostId: hostId);
    // Listening keeps the live state (and its stream) running after the screen closes.
    _live = ref.listen(velourStateProvider(hostId), (_, next) => _push(hostId, next.value), fireImmediately: true);
  }

  void _detach({bool dispose = false}) {
    _live?.close();
    _live = null;
    _lastKey = '';
    if (!dispose && state.hostId != null) state = VelourMediaState(enabled: state.enabled);
    if (supported) unawaited(_native(TiphysNative.velourMediaStop));
  }

  void _push(String hostId, VState? s) {
    final t = s?.track;
    if (s == null || t == null) {
      if (_lastKey.isNotEmpty) unawaited(_native(TiphysNative.velourMediaStop));
      _lastKey = '';
      return;
    }
    // Only real changes (the position runs on by itself on Android).
    final key = '${t.videoId}|${s.playing}|${s.rev ?? s.position.round()}|${t.like}';
    if (key == _lastKey) return;
    _lastKey = key;
    final l = _l;
    if (l == null) return;
    final now = ref.read(clockProvider)();
    unawaited(_native(() => TiphysNative.velourMediaUpdate({
          'title': t.title,
          'artist': t.artistLine,
          'album': t.album?.name ?? '',
          'art': t.thumbnail,
          'durationMs': (s.length * 1000).round(),
          'positionMs': (s.positionAt(now) * 1000).round(),
          'playing': s.playing,
          'host': ref.read(profileProvider).host(hostId)?.name,
          'channelName': l.velourNotifChannel,
          'labels': {'prev': l.mediaPrevious, 'play': l.mediaPlay, 'pause': l.mediaPause, 'next': l.mediaNext},
        })));
  }

  Future<void> _send(Map<String, Object?> op) async {
    final host = state.hostId ?? _screenHost;
    if (host == null) return;
    try {
      final r = await velourGet(ref, host, op);
      ref.read(velourStateProvider(host).notifier).apply(r);
    } catch (_) {
      // The notification shows the state that comes next; nothing to show it on here.
    }
  }

  void _onMedia(String action, int? ms) {
    final s = state.hostId == null ? null : ref.read(velourStateProvider(state.hostId!)).value;
    switch (action) {
      case 'play' || 'pause':
        // toggle, but only if it changes something (a stale lock-screen tap shouldn't flip it twice).
        if (s == null || s.playing != (action == 'play')) unawaited(_send({'op': 'toggle'}));
      case 'next':
        unawaited(_send({'op': 'next'}));
      case 'prev':
        unawaited(_send({'op': 'prev'}));
      case 'seek' when ms != null:
        unawaited(_send({'op': 'seek', 'seconds': ms / 1000}));
      case 'stop':
        _detach();
    }
  }

  void _onVolumeKey(bool up) {
    final host = _screenHost;
    if (host == null) return;
    final s = ref.read(velourStateProvider(host)).value;
    if (s == null) return;
    final v = (s.volume + (up ? 5 : -5)).clamp(0, 100).roundToDouble();
    final live = ref.read(velourStateProvider(host).notifier);
    live.patch((x, now) => x.copyWith(now, volume: v, muted: false));
    _volume.add(v.round());
    unawaited(_send({'op': 'volume', 'percent': v}));
  }

  Future<void> _native(Future<void> Function() f) async {
    try {
      await f();
    } on MissingPluginException {
      // Not on Android.
    } on PlatformException {
      // A failed notification isn't worth an error on screen.
    }
  }
}

final velourMediaProvider = NotifierProvider<VelourMedia, VelourMediaState>(VelourMedia.new);
