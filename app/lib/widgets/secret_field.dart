// Secret field: the value is never shown; the "saved" state appears in the hint.
// If the field is empty on save, the existing value is kept.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/profile/model.dart';
import '../core/secrets/secret_store.dart';
import '../l10n/gen/app_localizations.dart';
import '../state/providers.dart';

class SecretInput {
  SecretInput(this.secretId);
  String secretId;
  final controller = TextEditingController();

  String get ref => refOf(secretId);

  /// Writes to the vault if a new value was entered.
  Future<void> commit(SecretStore store) async {
    final v = controller.text;
    if (v.isNotEmpty) await store.write(secretId, v);
  }

  void dispose() => controller.dispose();
}

class SecretFieldView extends ConsumerWidget {
  const SecretFieldView({super.key, required this.input, required this.label, this.multiline = false, this.requiredWhenMissing = true});
  final SecretInput input;
  final String label;
  final bool multiline;
  final bool requiredWhenMissing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final stored = ref.watch(secretIdsProvider).value?.contains(input.secretId) ?? false;
    return TextFormField(
      controller: input.controller,
      obscureText: !multiline,
      maxLines: multiline ? 4 : 1,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: stored ? '•••••••• ✓' : null,
        helperText: stored ? l.secretStoredSafely : l.secretMissing(input.secretId),
        helperMaxLines: 2,
        floatingLabelBehavior: stored ? FloatingLabelBehavior.always : null,
      ),
      validator: (v) => requiredWhenMissing && !stored && (v ?? '').isEmpty ? l.commonRequired : null,
    );
  }
}
