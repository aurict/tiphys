// Texts of the game-mode screens that depend on agent codes (PLAN.md §19, contract section).
import '../../l10n/gen/app_localizations.dart';

String gameModeErrorText(AppLocalizations l, String code) => switch (code) {
  'agent.gamemode.noSource' => l.gmErrNoSource,
  'agent.gamemode.noDisplay' => l.gmErrNoDisplay,
  'agent.gamemode.startFailed' => l.gmErrStartFailed,
  'agent.gamemode.noGame' => l.gmPluginNoGame,
  'agent.gamemode.noArt' => l.gmErrNoArt,
  'agent.gamemode.pluginDownloadFailed' => l.gmErrPluginDownloadFailed,
  'agent.gamemode.pluginHashMismatch' => l.gmErrPluginHashMismatch,
  'agent.gamemode.pluginBadArchive' => l.gmErrPluginBadArchive,
  _ => '${l.commonError} ($code)',
};
