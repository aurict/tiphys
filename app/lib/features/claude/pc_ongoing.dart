// While a Claude session using the PC is "held" on the phone (10.3): the control session does NOT CLOSE when leaving
// the chat or when the app goes to the background (so the user can hand off the task and pocket the phone). Instead:
// - a non-dismissible local notification "Claude is using the PC" (countdown + "Stop"; body = PC chat),
// - the control token in secure storage (so "Stop"/"Extend" can reach the agent while the app is closed), only
// for the session's duration.
// When the control session ends (Stop, timeout, agent notice, other path) the notification and token go away. The
// control's own duration (15 min, extendable), the border on the PC and notify-send carry on as before.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/push/push_service.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../desktop/desktop_data.dart';
import '../system/agent_providers.dart';

/// Surface of the persistent notification (faked in tests).
abstract class PcNotifications {
  Future<void> show(AppLocalizations l, PcHold h);
  Future<void> cancel();
}

class _PluginPcNotifications implements PcNotifications {
  final _n = FlutterLocalNotificationsPlugin();
  @override
  Future<void> show(AppLocalizations l, PcHold h) => showPcOngoing(_n, l, h);
  @override
  Future<void> cancel() => _n.cancel(id: pcOngoingId);
}

final pcNotificationsProvider = Provider<PcNotifications>((ref) => _PluginPcNotifications());

class PcOngoing extends Notifier<PcHold?> {
  AppLocalizations? _l;

  @override
  PcHold? build() {
    // Control session closed / extended / token refreshed → the notification and stored record are updated.
    ref.listen<ControlSession?>(controlProvider, (prev, next) {
      final h = state;
      if (h == null) return;
      if (next == null || next.hostId != h.hostId) {
        unawaited(release());
      } else if (next.token != h.token || next.expiresAt != h.expiresAt) {
        unawaited(_put(h.copyWith(token: next.token, expiresAt: next.expiresAt)));
      }
    });
    return null;
  }

  /// This Claude session holds the open control session (called by the chat screen when it binds the control).
  Future<void> hold({required String hostId, required String sessionId, required String title, required AppLocalizations l}) async {
    _l = l;
    final s = ref.read(controlProvider);
    if (s == null || s.hostId != hostId) return;
    final h = state;
    if (h != null && h.sessionId == sessionId && h.token == s.token && h.expiresAt == s.expiresAt) return;
    await _put(PcHold(hostId: hostId, sessionId: sessionId, title: title, token: s.token, expiresAt: s.expiresAt));
  }

  Future<void> _put(PcHold h) async {
    state = h;
    ref.read(controlProvider.notifier).pcHold = h.sessionId;
    await ref.read(secretStoreProvider).write(pcControlSecretId, jsonEncode(h.toJson()));
    final l = _l;
    if (l != null) await ref.read(pcNotificationsProvider).show(l, h);
  }

  /// Holding ended: the notification goes away, the token is deleted. Does not touch the control session.
  Future<void> release() async {
    if (!ref.mounted || state == null) return;
    state = null;
    ref.read(controlProvider.notifier).pcHold = null;
    await ref.read(secretStoreProvider).delete(pcControlSecretId);
    await ref.read(pcNotificationsProvider).cancel();
  }

  /// Notification button (while the app is open): Stop = close control (the agent also stops Claude), Extend = 15 min.
  Future<bool> action(String id) async {
    final h = state;
    if (h == null) return false;
    final ctrl = ref.read(controlProvider.notifier);
    if (id == actionPcStop) {
      try {
        final host = ref.read(profileProvider).host(h.hostId);
        if (host != null) {
          final c = await ref.read(agentClientFactoryProvider)(host);
          try {
            await c.post('/v1/claude/sessions/${h.sessionId}/interrupt');
          } finally {
            c.close();
          }
        }
      } catch (_) {
        // Claude may already be stopped; closing control is enough (the agent also stops Claude when control ends).
      }
      await ctrl.stop();
      return true;
    }
    if (id == actionPcExtend) {
      try {
        await ctrl.extend();
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  /// The agent reported the control ended (push or chat event): release this session if we hold it, forget the old token.
  void ended(String sessionId) {
    final h = state;
    if (h == null || h.sessionId != sessionId) return;
    unawaited(release());
    final s = ref.read(controlProvider);
    if (s != null && s.token == h.token) ref.read(controlProvider.notifier).forget();
  }
}

final pcOngoingProvider = NotifierProvider<PcOngoing, PcHold?>(PcOngoing.new);
