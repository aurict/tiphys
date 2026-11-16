// Shows the lock screen when the app opens and after it stays in the background longer than the set time.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/security/app_lock.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/surfaces.dart';

final appLockProvider = Provider<AppLock>((ref) => AppLock(const SecureVault()));
final biometricsProvider = Provider<Biometrics>((ref) => DeviceBiometrics());

/// Is a lock needed? (PIN set, or fingerprint enabled and available on the device)
final lockRequiredProvider = FutureProvider<bool>((ref) async {
  final lock = ref.watch(profileProvider.select((p) => p.app.lock));
  final hasPin = lock.pin && await ref.read(appLockProvider).hasPin();
  final bio = lock.biometric && await ref.read(biometricsProvider).available();
  return hasPin || bio;
});

class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> with WidgetsBindingObserver {
  bool _locked = true;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final at = _pausedAt;
      _pausedAt = null;
      final after = ref.read(profileProvider).app.lock.autoLockSeconds;
      if (at != null && DateTime.now().difference(at).inSeconds >= after) setState(() => _locked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final required = ref.watch(lockRequiredProvider);
    final mustLock = required.value ?? true;
    if (required.isLoading) return ColoredBox(color: context.tokens.background);
    if (!mustLock || !_locked) return widget.child;
    return LockScreen(onUnlocked: () => setState(() => _locked = false));
  }
}

class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key, required this.onUnlocked, this.title, this.onCancel});
  final VoidCallback onUnlocked;

  /// Title and cancel button for re-authentication while the app is open (e.g. password vault).
  final String? title;
  final VoidCallback? onCancel;

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  String _pin = '';
  bool _wrong = false;
  int _wait = 0;
  bool _busy = false;
  bool _hasPin = false;
  bool _bio = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final lock = ref.read(profileProvider).app.lock;
    final hasPin = lock.pin && await ref.read(appLockProvider).hasPin();
    final bio = lock.biometric && await ref.read(biometricsProvider).available();
    if (!mounted) return;
    setState(() {
      _hasPin = hasPin;
      _bio = bio;
    });
    if (bio) _biometric();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _biometric() async {
    final l = AppLocalizations.of(context);
    if (await ref.read(biometricsProvider).authenticate(l.lockBiometricReason)) widget.onUnlocked();
  }

  Future<void> _digit(String d) async {
    if (_busy || _wait > 0 || _pin.length >= 12) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += d;
      _wrong = false;
    });
    if (_pin.length >= 6) await _tryPin(auto: true);
  }

  Future<void> _tryPin({bool auto = false}) async {
    setState(() => _busy = true);
    final res = await ref.read(appLockProvider).verify(_pin);
    if (!mounted) return;
    if (res.ok) {
      widget.onUnlocked();
      return;
    }
    // Only evaluate at full length so PINs longer than 6 digits don't count as wrong in auto-attempts.
    setState(() {
      _busy = false;
      if (!auto || res.waitSeconds > 0 || _pin.length >= 12) {
        _wrong = true;
        _pin = '';
      }
      _wait = res.waitSeconds;
    });
    if (_wait > 0) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return t.cancel();
        setState(() => _wait = (_wait - 1).clamp(0, 1 << 30));
        if (_wait == 0) t.cancel();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    Widget key(String label, {VoidCallback? onTap, IconData? icon, String? semantics}) => Semantics(
          button: true,
          label: semantics ?? label,
          child: SizedBox(
            width: 76,
            height: 76,
            child: TCard(
              radius: 38,
              padding: EdgeInsets.zero,
              onTap: onTap,
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 24, color: t.text)
                    : Text(label, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: t.text)),
              ),
            ),
          ),
        );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AmbientBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset('assets/brand/icon.png', width: 64, height: 64, semanticLabel: l.appName),
                ),
                const SizedBox(height: 14),
                Text(widget.title ?? l.lockTitle, style: tt.titleLarge),
                const SizedBox(height: 8),
                SizedBox(
                  height: 22,
                  child: Text(
                    _wait > 0 ? '${l.securityPinWrong} · $_wait s' : (_wrong ? l.securityPinWrong : (_hasPin ? l.securityPinEnter : '')),
                    style: tt.bodySmall?.copyWith(color: _wrong || _wait > 0 ? t.danger : t.textSecondary),
                  ),
                ),
                if (_hasPin) ...[
                  const SizedBox(height: 10),
                  Semantics(
                    label: l.securityPinEnter,
                    value: '${_pin.length}',
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      for (var i = 0; i < (_pin.length > 6 ? _pin.length : 6); i++)
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 7),
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _pin.length ? t.text : Colors.transparent,
                            border: Border.all(color: t.text, width: 1.5),
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 28),
                  for (final row in const [
                    ['1', '2', '3'],
                    ['4', '5', '6'],
                    ['7', '8', '9'],
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        for (final d in row) Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: key(d, onTap: () => _digit(d))),
                      ]),
                    ),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: _bio
                          ? key('', icon: LucideIcons.fingerprint, onTap: _biometric, semantics: l.securityBiometric)
                          : const SizedBox(width: 76),
                    ),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: key('0', onTap: () => _digit('0'))),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: key('', icon: LucideIcons.delete, semantics: l.commonDelete, onTap: () {
                        if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1));
                      }),
                    ),
                  ]),
                ] else if (_bio) ...[
                  const SizedBox(height: 24),
                  FilledButton.icon(onPressed: _biometric, icon: const Icon(LucideIcons.fingerprint), label: Text(l.lockUnlock)),
                ],
                if (widget.onCancel != null) ...[
                  const SizedBox(height: 12),
                  TextButton(onPressed: widget.onCancel, child: Text(l.commonCancel)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
