// Files › Transfers page: running, paused, interrupted, archiving and finished transfers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiphys/core/profile/model.dart';
import 'package:tiphys/features/files/transfers.dart';

import '../helpers/harness.dart';

class _Preset extends Transfers {
  @override
  List<Transfer> build() {
    const h = Host(id: 'atlas', name: 'atlas', address: 'atlas');
    Transfer t(TransferKind k, String name, TransferState s, int done, int size, {bool folder = false}) =>
        Transfer(kind: k, host: h, name: name, remote: '/srv', size: size, folder: folder)
          ..state = s
          ..done = done;
    return [
      t(TransferKind.download, 'yedek-2026-11-14.sql.gz', TransferState.running, 412 << 20, 1100 << 20),
      t(TransferKind.upload, 'IMG_2041.mp4', TransferState.paused, 96 << 20, 240 << 20),
      t(TransferKind.download, 'proje', TransferState.preparing, 0, 0, folder: true),
      t(TransferKind.download, 'grafana.db', TransferState.failed, 3 << 20, 18 << 20),
      t(TransferKind.upload, 'notlar.md', TransferState.done, 4096, 4096),
    ];
  }
}

void main() {
  testWidgets('aktarımlar sayfası', (tester) async {
    await Harness(extra: [transfersProvider.overrideWith(_Preset.new)]).pump(tester, route: '/files');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle(tester);
    await tester.tap(find.byTooltip('Aktarımlar (2 sürüyor)'));
    await settle(tester);
    expect(find.text('Klasör sunucuda sıkıştırılıyor…', findRichText: true), findsNothing); // with the host prefix in the row
    expect(find.textContaining('Klasör sunucuda sıkıştırılıyor'), findsOneWidget);
    await golden('png/files_transfers_light_tr.png');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });
}
