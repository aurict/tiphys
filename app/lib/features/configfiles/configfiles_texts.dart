// Texts of the config editor (PLAN.md §13.3): error codes, skip reasons, warnings and issue lines.
import '../../l10n/gen/app_localizations.dart';
import 'configfiles_data.dart';

/// agent.configfiles.* → text. Values never appear in these messages (the agent sends key names and line numbers only).
String configErrorText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) => switch (code) {
      'agent.configfiles.notFound' => l.errCfNotFound,
      'agent.configfiles.notEditable' => l.errCfNotEditable(skipReasonText(l, '${params['reason'] ?? ''}')),
      'agent.configfiles.fileChanged' => l.errCfFileChanged,
      'agent.configfiles.conflict' => l.errCfConflict,
      'agent.configfiles.notText' => l.errCfNotText,
      'agent.configfiles.keyNotFound' => l.errCfKeyNotFound('${params['key'] ?? ''}'),
      'agent.configfiles.keyExists' => l.errCfKeyExists('${params['key'] ?? ''}'),
      'agent.configfiles.unterminatedQuote' => l.errCfUnterminatedQuote('${params['line'] ?? ''}'),
      'agent.configfiles.noChange' => l.errCfNoChange,
      'agent.configfiles.tooLarge' => l.errCfTooLarge,
      'agent.configfiles.confirmRequired' => l.errCfConfirmRequired,
      'agent.configfiles.restartUnavailable' => l.errCfRestartUnavailable,
      'agent.configfiles.nothingToRestart' => l.errCfNothingToRestart,
      'agent.configfiles.restartRateLimited' => l.errCfRestartRateLimited('${params['limit'] ?? ''}', '${((params['windowSeconds'] as num?) ?? 600) ~/ 60}'),
      'agent.configfiles.rateLimited' => l.errCfRateLimited,
      'agent.configfiles.backupNotFound' => l.errCfBackupNotFound,
      _ => '${l.commonError} ($code)',
    };

/// Errors after which the file has to be read again: someone changed it, or it stopped qualifying.
bool configNeedsReload(String code) => code == 'agent.configfiles.conflict' || code == 'agent.configfiles.fileChanged';

/// Why a file is not offered (the `skipped` list) or can't be edited.
String skipReasonText(AppLocalizations l, String reason) => switch (reason) {
      'notRegular' => l.cfSkipNotRegular,
      'notOwner' => l.cfSkipNotOwner,
      'tooLarge' => l.cfSkipTooLarge,
      'badName' => l.cfSkipBadName,
      'outsideRoot' => l.cfSkipOutsideRoot,
      'missing' => l.cfSkipMissing,
      'moved' => l.cfSkipMoved,
      'replaced' => l.cfSkipReplaced,
      'notText' => l.cfSkipNotText,
      'unreadable' => l.cfSkipUnreadable,
      _ => reason,
    };

String configWarningText(AppLocalizations l, String code, String mode) => switch (code) {
      'worldReadable' => mode.isEmpty ? l.cfWarnWorldReadableShort : l.cfWarnWorldReadable(mode),
      _ => code,
    };

String configIssueText(AppLocalizations l, ConfigIssue i) => switch (i.reason) {
      'unterminatedQuote' => l.cfIssueUnterminated(i.line),
      'trailingText' => l.cfIssueTrailing(i.line),
      _ => l.cfIssueSyntax(i.line),
    };

String changeKindName(AppLocalizations l, String kind) => switch (kind) {
      'added' => l.cfChangeAdded,
      'removed' => l.cfChangeRemoved,
      'renamed' => l.cfChangeRenamed,
      _ => l.cfChangeChanged,
    };
