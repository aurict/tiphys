// Ajan eşleştirme: `tiphys-agent pair` komutunun bastığı QR kodu okutulur.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/agent/agent_client.dart';
import '../../l10n/gen/app_localizations.dart';

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
      appBar: AppBar(title: Text(l.pairScanTitle)),
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
