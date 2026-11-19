// Pieces shared by the security center's section screens (S-2…S-5): one block per agent with the feature, the
// loading/error wrapper, notes, a one-line text prompt and the "shown once" sheet for decoy tokens and recovery codes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/theme.dart' show monoFamily;
import '../../theme/tokens.dart';
import '../../widgets/forms.dart';
import '../../widgets/surfaces.dart';
import '../system/agent_providers.dart';
import '../vault/vault_state.dart' show secureWindowProvider, sensitiveClipboardProvider;
import 'security_more_data.dart';

/// One block per agent that has the `security` feature (the one a deep link names, else all of them). Several agents
/// get a heading each.
class SecurityAgentBlocks extends ConsumerWidget {
  const SecurityAgentBlocks({super.key, required this.hint, required this.builder});
  final String? hint;
  final Widget Function(BuildContext context, Host agent) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final agents = ref.watch(securityAgentsProvider(hint));
    return agents.when(
      skipLoadingOnRefresh: true,
      loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => TCard(child: Text(agentErrorText(l, e))),
      data: (list) {
        if (list.isEmpty) return TCard(child: Text(l.secNoAgents));
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final a in list) ...[
            if (list.length > 1) SectionLabel(a.name),
            builder(context, a),
          ],
        ]);
      },
    );
  }
}

/// Loading spinner, error card with "Retry" and the data builder.
class SecAsync<T> extends StatelessWidget {
  const SecAsync({super.key, required this.value, required this.onRetry, required this.data, this.error});
  final AsyncValue<T> value;
  final VoidCallback onRetry;
  final Widget Function(T) data;

  /// Own text for some errors (e.g. "not local" on the black box); null = the generic card.
  final Widget? Function(Object error)? error;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    return value.when(
      skipLoadingOnRefresh: true,
      loading: () => const Padding(padding: EdgeInsets.all(28), child: Center(child: CircularProgressIndicator())),
      error: (e, _) =>
          error?.call(e) ??
          TCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(LucideIcons.circleAlert, color: t.danger, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(agentErrorText(l, e))),
              ]),
              TextButton(onPressed: onRetry, child: Text(l.commonRetry)),
            ]),
          ),
      data: data,
    );
  }
}

/// A card with an icon and explanatory text (warnings use [warn]).
class SecNote extends StatelessWidget {
  const SecNote(this.text, {super.key, this.icon = LucideIcons.info, this.warn = false, this.title});
  final String text;
  final String? title;
  final IconData icon;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    final c = warn ? t.warning : t.textSecondary;
    return TCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(warn ? LucideIcons.triangleAlert : icon, size: 18, color: c),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (title != null) Text(title!, style: tt.titleSmall),
            Text(text, style: tt.bodyMedium),
          ]),
        ),
      ]),
    );
  }
}

/// Runs an agent call: a snackbar with [ok] on success, with the agent's error text on failure; true on success.
Future<bool> secAct(BuildContext context, Future<void> Function() body, {String? ok}) async {
  final l = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await body();
    if (ok != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ok)));
    }
    return true;
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(agentErrorText(l, e))));
    return false;
  }
}

/// One-line prompt in a dialog; null on cancel. [validator] returns an error text or null.
Future<String?> secAskText(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
  String? helper,
  String initial = '',
  bool mono = false,
  bool obscure = false,
  TextInputType? keyboardType,
  String? Function(String)? validator,
  String? action,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _AskDialog(title: title, label: label, hint: hint, helper: helper, initial: initial, mono: mono, obscure: obscure, keyboardType: keyboardType, validator: validator, action: action),
    );

class _AskDialog extends StatefulWidget {
  const _AskDialog({required this.title, required this.label, this.hint, this.helper, required this.initial, required this.mono, required this.obscure, this.keyboardType, this.validator, this.action});
  final String title, label, initial;
  final String? hint, helper, action;
  final bool mono, obscure;
  final TextInputType? keyboardType;
  final String? Function(String)? validator;
  @override
  State<_AskDialog> createState() => _AskDialogState();
}

class _AskDialogState extends State<_AskDialog> {
  late final _c = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _ok() {
    final v = _c.text.trim();
    final err = widget.validator?.call(v);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _c,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: !widget.obscure && !widget.mono,
        obscureText: widget.obscure,
        keyboardType: widget.keyboardType,
        style: widget.mono ? const TextStyle(fontFamily: monoFamily, fontSize: 13) : null,
        decoration: InputDecoration(labelText: widget.label, hintText: widget.hint, helperText: widget.helper, helperMaxLines: 4, errorText: _error, errorMaxLines: 3),
        onSubmitted: (_) => _ok(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.commonCancel)),
        TextButton(onPressed: _ok, child: Text(widget.action ?? l.commonAdd)),
      ],
    );
  }
}

/// A list of chips (owners, zones, IPs, …) with a remove button each and an "Add" chip.
class SecChipList extends StatelessWidget {
  const SecChipList({super.key, required this.items, required this.onAdd, required this.onRemove, required this.addLabel, this.mono = true, this.enabled = true, this.removeLabel});
  final List<String> items;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;
  final String addLabel;
  final String Function(String item)? removeLabel;
  final bool mono, enabled;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final i in items)
          InputChip(
            label: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width - 130),
              child: Text(i, overflow: TextOverflow.ellipsis, style: mono ? const TextStyle(fontFamily: monoFamily, fontSize: 13) : null),
            ),
            deleteButtonTooltipMessage: removeLabel?.call(i) ?? MaterialLocalizations.of(context).deleteButtonTooltip,
            onDeleted: enabled ? () => onRemove(i) : null,
          ),
        ActionChip(avatar: const Icon(LucideIcons.plus, size: 16), label: Text(addLabel), onPressed: enabled ? onAdd : null),
      ]);
}

/// Shows a secret exactly once: FLAG_SECURE while open (no screenshots / recents preview), not dismissible by a tap
/// outside, closed when the app goes to the background. [copyable] adds a copy button that uses the sensitive clipboard
/// (cleared after 30 s); recovery codes are meant for paper and have none.
Future<void> showSecretOnce(
  BuildContext context, {
  required String title,
  required String value,
  required String hint,
  String? warning,
  bool copyable = true,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => _SecretOnceSheet(title: title, value: value, hint: hint, warning: warning, copyable: copyable),
    );

class _SecretOnceSheet extends ConsumerStatefulWidget {
  const _SecretOnceSheet({required this.title, required this.value, required this.hint, this.warning, required this.copyable});
  final String title, value, hint;
  final String? warning;
  final bool copyable;
  @override
  ConsumerState<_SecretOnceSheet> createState() => _SecretOnceSheetState();
}

class _SecretOnceSheetState extends ConsumerState<_SecretOnceSheet> with WidgetsBindingObserver {
  late final Future<void> Function(bool) _secure;
  late final _clipboard = ref.read(sensitiveClipboardProvider);

  @override
  void initState() {
    super.initState();
    _secure = ref.read(secureWindowProvider);
    WidgetsBinding.instance.addObserver(this);
    _secure(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _secure(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Removes this sheet's own route: maybePop() would respect PopScope(canPop: false) and stay open, and pop() would
    // close whatever is on top by then (e.g. the app lock screen pushed when the app went to the background).
    if (state != AppLifecycleState.paused || !mounted) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = context.tokens;
    final tt = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Semantics(header: true, child: Text(widget.title, style: tt.titleLarge)),
              const SizedBox(height: 10),
              Text(l.secOnceShownOnce, style: tt.bodyMedium?.copyWith(color: t.warning, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TCard(
                semanticLabel: widget.title,
                child: SelectionContainer.disabled(
                  child: Text(widget.value, key: const Key('secret-once-value'), style: const TextStyle(fontFamily: monoFamily, fontSize: 16, height: 1.5, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 12),
              Text(widget.hint, style: tt.bodyMedium),
              if (widget.warning != null) ...[const SizedBox(height: 10), Text(widget.warning!, style: tt.bodySmall?.copyWith(color: t.warning))],
              const SizedBox(height: 16),
              if (widget.copyable)
                OutlinedButton.icon(
                  onPressed: () async {
                    await _clipboard.copy(widget.value);
                    if (context.mounted) toast(context, l.secOnceCopied);
                  },
                  icon: const Icon(LucideIcons.copy, size: 16),
                  label: Text(l.secOnceCopy),
                ),
              const SizedBox(height: 8),
              FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.secOnceDone)),
            ]),
          ),
        ),
      ),
    );
  }
}
