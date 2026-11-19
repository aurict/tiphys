// Texts of the agy screens that depend on agent codes and ids (every id has Turkish and English text in the arb files).
import '../../l10n/gen/app_localizations.dart';

/// Codes the agent sends for agy (agent/src/agy/{acp,manager,routes}.ts).
const agyErrorCodes = [
  'agent.agy.missing',
  'agent.agy.exited',
  'agent.agy.timeout',
  'agent.agy.rpcError',
  'agent.agy.busy',
  'agent.agy.sessionNotFound',
  'agent.agy.sessionEnded',
  'agent.agy.tooManySessions',
  'agent.agy.alreadyOpen',
  'agent.agy.permissionNotFound',
  'agent.agy.unknownMode',
  'agent.agy.unknownModel',
  'agent.agy.startFailed',
  'agent.agy.promptFailed',
  'agent.agy.rateLimited',
];

String agyErrorText(AppLocalizations l, String code) => switch (code) {
  'agent.agy.missing' => l.agyErrMissing,
  'agent.agy.exited' => l.agyErrExited,
  'agent.agy.timeout' => l.agyErrTimeout,
  'agent.agy.rpcError' => l.agyErrRpc,
  'agent.agy.busy' => l.agyErrBusy,
  'agent.agy.sessionNotFound' => l.agyErrSessionNotFound,
  'agent.agy.sessionEnded' => l.agyErrSessionEnded,
  'agent.agy.tooManySessions' => l.agyErrTooMany,
  'agent.agy.alreadyOpen' => l.agyErrAlreadyOpen,
  'agent.agy.permissionNotFound' => l.agyErrPermissionNotFound,
  'agent.agy.unknownMode' => l.agyErrUnknownMode,
  'agent.agy.unknownModel' => l.agyErrUnknownModel,
  'agent.agy.startFailed' => l.agyErrStartFailed,
  'agent.agy.promptFailed' => l.agyErrPromptFailed,
  'agent.agy.rateLimited' => l.agyErrRateLimited,
  _ => '${l.commonError} ($code)',
};

/// Modes the new-session sheet offers (agy's own list comes with the session; see agent/src/agy/manager.ts).
const agyKnownModes = ['default', 'accept-edits', 'auto', 'plan'];

/// Short name of a mode in the app's language; the agent's own name for ids this app doesn't know.
String agyModeLabel(AppLocalizations l, String id, [String? agentName]) => switch (id) {
  'default' => l.agyModeDefault,
  'accept-edits' => l.agyModeAcceptEdits,
  'auto' => l.agyModeAuto,
  'plan' => l.agyModePlan,
  _ => (agentName == null || agentName.isEmpty) ? id : agentName,
};

/// One-sentence explanation of a mode; null for ids this app doesn't know (the agent's description is used then).
String? agyModeHint(AppLocalizations l, String id) => switch (id) {
  'default' => l.agyModeHintDefault,
  'accept-edits' => l.agyModeHintAcceptEdits,
  'auto' => l.agyModeHintAuto,
  'plan' => l.agyModeHintPlan,
  _ => null,
};

String agyStatusText(AppLocalizations l, String s) => switch (s) {
  'running' || 'starting' => l.claudeStatusRunning,
  'waiting' => l.claudeStatusWaiting,
  'idle' => l.claudeStatusIdle,
  'error' => l.claudeStatusError,
  _ => l.claudeStatusStopped,
};

/// Text of an `error` event: the agent's code when it is one, else the line as is ("agy exited").
String agyEventErrorText(AppLocalizations l, String text) => text.startsWith('agent.agy.') ? agyErrorText(l, text) : text;
