// Password vault session: entries stay in memory only while the vault is open. Opening it asks for the app lock (PIN /
// fingerprint) again even if the app is unlocked. It locks on inactivity and when the app goes to the background;
// while vault pages are open the window is FLAG_SECURE (no screenshots / recent-apps preview).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:tiphys_native/tiphys_native.dart';

import '../../core/vault/sensitive_clipboard.dart';
import '../../core/vault/vault.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';
import '../lock/lock_gate.dart';

/// The vault locks if untouched for this long.
const vaultIdleTimeout = Duration(minutes: 2);

final vaultStoreProvider = Provider<VaultStore>((ref) => VaultStore(ref.watch(secretStoreProvider)));

/// Password copying (sensitive flag + clearing after 30 s). Kept alive so the timer survives the vault closing.
final sensitiveClipboardProvider = Provider<SensitiveClipboard>((ref) => SensitiveClipboard(TiphysSensitiveClipboard()));

/// Toggles FLAG_SECURE (recorded in tests). Silently skipped if there is no plugin.
final secureWindowProvider = Provider<Future<void> Function(bool)>((ref) => (on) async {
      try {
        await TiphysNative.setSecureWindow(on);
      } catch (_) {}
    });

/// Asks for the app lock again before opening the vault; true if verified. Replaced in tests.
final vaultAuthProvider = Provider<Future<bool> Function(BuildContext)>((ref) => (context) async {
      final l = AppLocalizations.of(context);
      final ok = await Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(
        fullscreenDialog: true,
        builder: (c) => PopScope(
          child: LockScreen(title: l.vaultTitle, onUnlocked: () => Navigator.of(c).pop(true), onCancel: () => Navigator.of(c).pop(false)),
        ),
      ));
      return ok ?? false;
    });

class VaultState {
  const VaultState(this.entries);
  static const locked = VaultState(null);

  /// null = locked.
  final List<VaultEntry>? entries;
  bool get unlocked => entries != null;
}

class VaultController extends Notifier<VaultState> {
  Timer? _idle;

  @override
  VaultState build() {
    ref.onDispose(() => _idle?.cancel());
    return VaultState.locked;
  }

  VaultStore get _store => ref.read(vaultStoreProvider);

  /// Called after authentication: reads the entries from storage.
  Future<void> open() async {
    state = VaultState(await _store.load());
    touch();
  }

  /// Resets the inactivity timer on interaction.
  void touch() {
    if (!state.unlocked) return;
    _idle?.cancel();
    _idle = Timer(vaultIdleTimeout, () => lock());
  }

  /// Locks the vault and drops the entries from memory. [clearClipboard]: whether a pending password copy is cleared
  /// immediately (not when going to the background: the user is likely pasting elsewhere; the 30 s timer runs).
  Future<void> lock({bool clearClipboard = true}) async {
    if (!ref.mounted) return; // while the app is closing (container disposed)
    _idle?.cancel();
    _idle = null;
    if (state.unlocked) state = VaultState.locked;
    if (clearClipboard) await ref.read(sensitiveClipboardProvider).clearNow();
  }

  /// No writes happen while locked: if a confirmation dialog left open is confirmed after the vault locked
  /// (going to the background, idling), there is no list at hand and an empty list would be written, wiping the vault.
  Future<void> _save(List<VaultEntry> next) async {
    if (!state.unlocked) throw const VaultLockedError();
    await _store.save(next);
    state = VaultState(next);
    touch();
  }

  Future<void> upsert(VaultEntry e) => state.unlocked ? _save(upsertEntry(state.entries!, e)) : Future.error(const VaultLockedError());

  Future<void> delete(String id) => state.unlocked ? _save([...state.entries!.where((e) => e.id != id)]) : Future.error(const VaultLockedError());

  Future<void> replaceAll(List<VaultEntry> entries) => _save(entries);
}

/// A change was attempted while the vault was locked; the user is asked to unlock again.
class VaultLockedError implements Exception {
  const VaultLockedError();
}

List<VaultEntry> upsertEntry(List<VaultEntry> list, VaultEntry e) {
  final i = list.indexWhere((x) => x.id == e.id);
  return i < 0 ? [...list, e] : ([...list]..[i] = e);
}

final vaultProvider = NotifierProvider<VaultController, VaultState>(VaultController.new);

/// Vault page scaffold: makes the window secure, resets the timer on touch, locks when going to the background.
/// While locked, a lock view is drawn instead of the content (sub-pages too; resumes where it left off when unlocked).
class VaultScope extends ConsumerStatefulWidget {
  const VaultScope({super.key, required this.builder, this.root = false});
  final Widget Function(BuildContext context, List<VaultEntry> entries) builder;

  /// Root vault page: starts authentication automatically on open, locks the vault on close.
  final bool root;

  /// Number of open vault pages: FLAG_SECURE is removed when the last one closes.
  static int _open = 0;

  @override
  ConsumerState<VaultScope> createState() => _VaultScopeState();
}

class _VaultScopeState extends ConsumerState<VaultScope> {
  late final AppLifecycleListener _life;
  late final Future<void> Function(bool) _secure;
  late final VaultController _vault;

  /// Authentication is requested automatically only on first open (after an inactivity lock, via the button).
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    _vault = ref.read(vaultProvider.notifier);
    _secure = ref.read(secureWindowProvider);
    if (VaultScope._open++ == 0) unawaited(_secure(true));
    _life = AppLifecycleListener(onStateChange: (s) {
      if (s == AppLifecycleState.hidden || s == AppLifecycleState.paused) _vault.lock(clearClipboard: false);
    });
  }

  @override
  void dispose() {
    _life.dispose();
    // Locks when leaving the vault; a copied password (e.g. to paste in a terminal) is cleared by the 30 s timer.
    if (widget.root) Future.microtask(() => _vault.lock(clearClipboard: false));
    if (--VaultScope._open == 0) unawaited(_secure(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(vaultProvider);
    final prompt = widget.root && !_prompted && !s.unlocked;
    if (prompt) _prompted = true;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _vault.touch(),
      child: s.unlocked ? widget.builder(context, s.entries!) : VaultLockedView(autoPrompt: prompt),
    );
  }
}

/// Locked vault: if no lock is set, directs to setting one up first; otherwise "Kasayı aç" (app lock asked again).
class VaultLockedView extends ConsumerStatefulWidget {
  const VaultLockedView({super.key, this.autoPrompt = false});

  /// Start authentication automatically on open (root page).
  final bool autoPrompt;
  @override
  ConsumerState<VaultLockedView> createState() => _VaultLockedViewState();
}

class _VaultLockedViewState extends ConsumerState<VaultLockedView> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoPrompt) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final required = await ref.read(lockRequiredProvider.future);
        if (mounted && required) _unlock();
      });
    }
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (await ref.read(vaultAuthProvider)(context)) await ref.read(vaultProvider.notifier).open();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final required = ref.watch(lockRequiredProvider);
    final hasLock = required.value ?? false;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: t.isDark ? const Color(0xCC000000) : t.background, // same as SettingsPage
        title: Text(l.vaultTitle),
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(LucideIcons.chevronLeft),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: AmbientBackground(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(TiphysTokens.gutter),
            child: TCard(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(LucideIcons.lockKeyhole, size: 40, color: t.accent),
                const SizedBox(height: 12),
                Text(l.vaultLocked, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(required.isLoading ? '' : (hasLock ? l.vaultLockedHint : l.vaultNeedsLock), textAlign: TextAlign.center, style: TextStyle(color: t.textSecondary)),
                const SizedBox(height: 16),
                if (required.isLoading)
                  const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                else if (hasLock)
                  FilledButton.icon(onPressed: _busy ? null : _unlock, icon: const Icon(LucideIcons.lockOpen), label: Text(l.vaultUnlock))
                else
                  FilledButton.icon(
                    onPressed: () => context.push('/settings/security'),
                    icon: const Icon(LucideIcons.shield),
                    label: Text(l.settingsSecurity),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
