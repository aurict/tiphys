// Texts of the game-mode screens that depend on agent codes (PLAN.md §19, contract section).
import '../../l10n/gen/app_localizations.dart';

String gameModeErrorText(AppLocalizations l, String code) => switch (code) {
  'agent.gamemode.noSource' => l.gmErrNoSource,
  'agent.gamemode.noDisplay' => l.gmErrNoDisplay,
  _ => '${l.commonError} ($code)',
};
