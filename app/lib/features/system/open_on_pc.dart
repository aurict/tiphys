// "Open on PC": the link opens in the PC's default browser (agent "desktop" feature, POST /v1/desktop/open).
// Uses the first http(s) link in text from the share menu or in the phone clipboard.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile/model.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../widgets/forms.dart';
import 'agent_providers.dart';

final _url = RegExp(r'''https?://[^\s<>"'`]+''', caseSensitive: false);

/// First http(s) link in the text; trailing sentence punctuation and an unmatched closing parenthesis are dropped.
String? findUrl(String text) {
  final m = _url.firstMatch(text);
  if (m == null) return null;
  var u = m.group(0)!;
  while (u.isNotEmpty) {
    final last = u[u.length - 1];
    if ('.,;:!?'.contains(last) || (last == ')' && '('.allMatches(u).length < ')'.allMatches(u).length)) {
      u = u.substring(0, u.length - 1);
    } else {
      break;
    }
  }
  final uri = Uri.tryParse(u);
  return uri == null || uri.host.isEmpty ? null : u;
}

/// Opens the link on the PC; the result is shown in a short notification. True on success.
Future<bool> openOnPc(BuildContext context, WidgetRef ref, Host host, String url) async {
  final l = AppLocalizations.of(context);
  try {
    await agentCall(ref, host.id, 'POST', '/v1/desktop/open', {'url': url});
    if (context.mounted) toast(context, l.openOnPcDone(host.name));
    return true;
  } catch (e) {
    if (context.mounted) toast(context, agentErrorText(l, e));
    return false;
  }
}

/// Opens the link from the phone clipboard on the PC (after confirming).
Future<void> openClipboardUrlOnPc(BuildContext context, WidgetRef ref, Host host) async {
  final l = AppLocalizations.of(context);
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  if (!context.mounted) return;
  final url = findUrl(text);
  if (url == null) {
    toast(context, l.openOnPcNoUrl);
    return;
  }
  if (!await confirmDialog(context, message: l.openOnPcConfirm(url, host.name), confirmLabel: l.openOnPc)) return;
  if (context.mounted) await openOnPc(context, ref, host, url);
}
