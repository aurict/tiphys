// Agent pairing: scans the QR code printed by the `tiphys-agent pair` command, or takes the same code pasted as text
// (platforms without a camera scanner, or a QR that can't be scanned).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/agent/agent_client.dart';
import '../../core/platform.dart';
import '../../l10n/gen/app_localizations.dart';

/// Pairing from pasted text: the QR payload JSON, or the "address + token" lines `tiphys-agent pair` prints below the
/// QR code (any text holding one http(s) URL and one `tph_` token). The agent name is the URL's first host label.
PairPayload? parsePairingText(String text) {
  final json = PairPayload.tryParse(text.trim());
  if (json != null) return json;
  final url = RegExp(r'https?://[^\s"<>]+').firstMatch(text)?.group(0);
  final token = RegExp(r'tph_[A-Za-z0-9_-]{8,}').firstMatch(text)?.group(0);
  if (url == null || token == null) return null;
  final host = Uri.tryParse(url)?.host ?? '';
  if (host.isEmpty) return null;
  return PairPayload(agent: host.split('.').first, url: url, token: token);
}

/// Scanner where there is a camera, otherwise straight to the paste dialog.
Future<PairPayload?> pickPairing(BuildContext context) => hasQrScanner ? PairScannerPage.open(context) : PairPasteDialog.open(context);

class PairScannerPage extends StatefulWidget {
  const PairScannerPage({super.key});

  static Future<PairPayload?> open(BuildContext context) =>
      Navigator.of(context).push<PairPayload>(MaterialPageRoute(builder: (_) => const PairScannerPage()));

  @override
  State<PairScannerPage> createState() => _PairScannerPageState();
}

class _PairScannerPageState extends State<PairScannerPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  String? _hint;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.pairScanTitle), actions: [
        TextButton.icon(
          onPressed: () async {
            final p = await PairPasteDialog.open(context);
            if (p != null && !_done && context.mounted) {
              _done = true;
              Navigator.of(context).pop(p);
            }
          },
          icon: const Icon(LucideIcons.clipboardPaste, size: 18),
          label: Text(l.pairPaste),
        ),
      ]),
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            if (_done) return;
            for (final b in capture.barcodes) {
              final p = PairPayload.tryParse(b.rawValue ?? '');
              if (p != null) {
                _done = true;
                Navigator.of(context).pop(p);
                return;
              }
            }
            setState(() => _hint = l.pairNotTiphys);
          },
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 32,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(_hint ?? l.pairScanHint, textAlign: TextAlign.center),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Paste the pairing code (QR text or address + token).
class PairPasteDialog extends StatefulWidget {
  const PairPasteDialog({super.key});

  static Future<PairPayload?> open(BuildContext context) => showDialog<PairPayload>(context: context, builder: (_) => const PairPasteDialog());

  @override
  State<PairPasteDialog> createState() => _PairPasteDialogState();
}

class _PairPasteDialogState extends State<PairPasteDialog> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final p = parsePairingText(_text.text);
    if (p == null) return setState(() => _error = AppLocalizations.of(context).pairPasteInvalid);
    Navigator.of(context).pop(p);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.pairPasteTitle),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.pairPasteHint, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5),
            decoration: InputDecoration(labelText: l.pairPasteLabel, errorText: _error, errorMaxLines: 3),
            onChanged: (_) => _error == null ? null : setState(() => _error = null),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final t = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
                if (t != null) setState(() => _text.text = t);
              },
              icon: const Icon(LucideIcons.clipboardPaste, size: 16),
              label: Text(l.pairPasteFromClipboard),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.commonCancel)),
        FilledButton(onPressed: _submit, child: Text(l.pairPasteUse)),
      ],
    );
  }
}
