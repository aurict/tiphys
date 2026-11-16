// Phone → PC clipboard sync: the clipboard is read when the app comes to the foreground; if "Sync clipboard with
// PC" is on and the text differs from the last seen one, it's sent to the selected PC's agent (PUT
// /v1/desktop/clipboard). Since Android doesn't allow reading the clipboard in the background, it's read only while
// the app is in the foreground (after the window gains focus). With the setting off the clipboard is never read.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile/model.dart';
import '../../core/push/clipboard.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../widgets/forms.dart';
import '../claude/claude_screen.dart' show outboxDirProvider;
import '../vault/vault_state.dart' show sensitiveClipboardProvider;
import 'package:tiphys_native/tiphys_native.dart';
import 'agent_providers.dart';

/// PC the clipboard syncs to: selected host, else the Claude host, else the first agent host (must have an agent).
Host? clipboardHost(Profile p) {
  Host? withAgent(String? id) {
    final h = p.host(id);
    return h?.agent == null ? null : h;
  }

  return withAgent(p.notifications.clipboardHostId) ?? withAgent(p.claude.agentHostId) ?? p.hosts.where((h) => h.agent != null).firstOrNull;
}

/// Function that reads the phone clipboard (overridden in tests).
final clipboardReaderProvider = Provider<Future<String?> Function()>((ref) => () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text);

/// Is the clipboard copy marked "sensitive" (a password from a password manager)? Overridden in tests.
/// If it can't be asked (no plugin, error) it counts as sensitive: content we can't be sure of doesn't go to the PC.
final clipboardSensitiveProvider = Provider<Future<bool> Function()>((ref) => () async {
      try {
        return await TiphysNative.isClipboardSensitive();
      } catch (_) {
        return true;
      }
    });

final clipboardSeenProvider = Provider<ClipboardSeen>((ref) => ClipboardSeen(ref.read(outboxDirProvider)));

/// Largest text sent to the PC (the agent's limit is 1 MB).
const _maxBytes = 1000000;

/// Checks the clipboard once; true if sent. Errors (agent down etc.) are thrown to the caller, not marked as seen.
Future<bool> syncClipboardToPc({
  required Profile profile,
  required Future<String?> Function() read,
  required ClipboardSeen seen,
  required Future<void> Function(Host host, String text) send,
  bool Function(String text)? skip,
  Future<bool> Function()? isSensitive,
}) async {
  if (!profile.notifications.clipboardToPc) return false;
  final host = clipboardHost(profile);
  if (host == null) return false;
  // A copy marked "sensitive" by the password manager (e.g. a password from Bitwarden) is never read or sent to the PC.
  if (isSensitive != null && await isSensitive()) return false;
  final text = await read();
  if (text == null || text.trim().isEmpty || utf8.encode(text).length > _maxBytes) return false;
  if (skip != null && skip(text)) return false; // e.g. a password copied from the vault
  if (!await seen.isNew(text)) return false;
  await send(host, text);
  await seen.mark(text);
  return true;
}

/// Wraps the unlocked part of the app: checks the clipboard on launch and every time it comes to the foreground.
class ClipboardSyncGate extends ConsumerStatefulWidget {
  const ClipboardSyncGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ClipboardSyncGate> createState() => _ClipboardSyncGateState();
}

class _ClipboardSyncGateState extends ConsumerState<ClipboardSyncGate> with WidgetsBindingObserver {
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _later();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _later();
  }

  /// On Android 10+ the clipboard reads empty before the window gains focus: read after a short delay.
  void _later() {
    _timer?.cancel();
    if (!ref.read(profileProvider).notifications.clipboardToPc) return;
    _timer = Timer(const Duration(milliseconds: 600), _check);
  }

  Future<void> _check() async {
    final profile = ref.read(profileProvider);
    if (_busy || !mounted || !profile.notifications.clipboardToPc) return;
    _busy = true;
    try {
      final sent = await syncClipboardToPc(
        profile: profile,
        read: ref.read(clipboardReaderProvider),
        seen: ref.read(clipboardSeenProvider),
        send: (host, text) async => agentCall(ref, host.id, 'PUT', '/v1/desktop/clipboard', {'text': text}),
        skip: ref.read(sensitiveClipboardProvider).isGuarded,
        isSensitive: ref.read(clipboardSensitiveProvider),
      );
      if (sent && mounted) toast(context, AppLocalizations.of(context).clipboardSent);
    } catch (_) {
      // PC is off or has no desktop feature: skip silently; retried the next time the app comes to the foreground.
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
