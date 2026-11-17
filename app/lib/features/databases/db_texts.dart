// Texts of the database console (PLAN.md §13.2): agent.db.* error codes and the small names the screens share.
// Driver messages arrive already redacted by the agent; they are shown as they are (never the SQL or a password).
import '../../l10n/gen/app_localizations.dart';

String dbErrorText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) {
  String p(String k) => '${params[k] ?? ''}';
  return switch (code) {
    'agent.db.connectionNotFound' => l.errDbConnectionNotFound,
    'agent.db.connectionExists' => l.errDbConnectionExists,
    'agent.db.passwordRequired' => l.errDbPasswordRequired,
    'agent.db.containerNotFound' => l.errDbContainerNotFound(p('container')),
    'agent.db.containerNotRunning' => l.errDbContainerNotRunning(p('container')),
    'agent.db.networkNotFound' => l.errDbNetworkNotFound(p('network')),
    'agent.db.containerNoAddress' => l.errDbContainerNoAddress,
    'agent.db.credentialUnavailable' => l.errDbCredentialUnavailable(p('reason')),
    'agent.db.unreachable' => l.errDbUnreachable(p('reason')),
    'agent.db.authFailed' => l.errDbAuthFailed,
    'agent.db.databaseNotFound' => l.errDbDatabaseNotFound,
    'agent.db.emptyStatement' => l.errDbEmptyStatement,
    'agent.db.multipleStatements' => l.errDbMultipleStatements,
    'agent.db.statementNotAllowed' => l.errDbStatementNotAllowed(p('keyword')),
    'agent.db.readOnly' => l.errDbReadOnly,
    'agent.db.permissionDenied' => l.errDbPermissionDenied(p('message')),
    'agent.db.queryFailed' => l.errDbQueryFailed(p('message')),
    'agent.db.timeout' => l.errDbTimeout,
    'agent.db.tableNotFound' => l.errDbTableNotFound,
    'agent.db.fileNotFound' => l.errDbFileNotFound,
    'agent.db.sqliteUnavailable' => l.errDbSqliteUnavailable,
    'agent.db.busy' => l.errDbBusy,
    'agent.db.rateLimited' => l.errDbRateLimited(p('perMinute')),
    'agent.db.exportRateLimited' => l.errDbExportRateLimited(p('perMinute')),
    'agent.db.writeRateLimited' => l.errDbWriteRateLimited(p('perTenMinutes')),
    'agent.db.queryNotFound' => l.errDbQueryNotFound,
    'agent.db.tooManyQueries' => l.errDbTooManyQueries(p('max')),
    'agent.db.writeUnsupported' => l.errDbWriteUnsupported,
    'agent.db.ddlNotPreviewable' => l.errDbDdlNotPreviewable(p('keyword')),
    'agent.db.nonTransactionalTables' => l.errDbNonTransactionalTables(((params['tables'] as List?) ?? const []).take(3).join(', ')),
    'agent.db.countChanged' => l.errDbCountChanged(p('expected'), p('actual')),
    'agent.db.restoreTestNotFound' => l.errDbRestoreTestNotFound,
    'agent.db.restoreTestExists' => l.errDbRestoreTestExists,
    'agent.db.restoreBusy' => l.errDbRestoreBusy,
    'agent.db.restoreEngineMismatch' => l.errDbRestoreEngineMismatch,
    'agent.db.sanityNotAllowed' => l.errDbSanityNotAllowed(((params['index'] as num?)?.toInt() ?? 0) + 1, p('keyword')),
    'agent.db.dumpOutsideRoots' => l.errDbDumpOutsideRoots,
    'agent.db.superuserReadsDisabled' => params['readRole'] == true ? l.errDbReadRoleSuperuser : l.errDbSuperuserReadsDisabled,
    'agent.db.failed' => l.errDbFailed,
    _ => '${l.commonError} ($code)',
  };
}

/// postgres → "PostgreSQL" (product names aren't translated).
String dbEngineName(String engine) => switch (engine) {
  'postgres' => 'PostgreSQL',
  'mysql' => 'MySQL',
  'mariadb' => 'MariaDB',
  'sqlite' => 'SQLite',
  'redis' => 'Redis',
  _ => engine,
};

String dbKindName(AppLocalizations l, String kind) => switch (kind) {
  'view' => l.dbKindView,
  'materializedView' => l.dbKindMatView,
  'foreignTable' => l.dbKindForeign,
  'partitionedTable' => l.dbKindPartitioned,
  _ => l.dbKindTable,
};

String dbChartName(AppLocalizations l, String type) => switch (type) {
  'stat' => l.dbChartStat,
  'line' => l.dbChartLine,
  'bar' => l.dbChartBar,
  _ => l.dbChartTable,
};

String dbWarningText(AppLocalizations l, String code) => switch (code) {
  'superuserCredential' => l.dbWarnSuperuser,
  'readCredentialUsed' => l.dbWarnReadUsed,
  'superuserReadsDisabled' => l.errDbSuperuserReadsDisabled,
  _ => code,
};

/// A restore result's failure reason (agent: db/restore.ts) → text; [detail] is the client's first error line.
String restoreReasonText(AppLocalizations l, String? reason, [String? detail]) {
  final base = switch (reason) {
    'noDump' => l.dbRrNoDump,
    'dumpOutsideRoots' => l.dbRrDumpOutside,
    'insufficientDisk' => l.dbRrDisk,
    'imageVersionMismatch' => l.dbRrImageVersion,
    'dockerFailed' => l.dbRrDocker,
    'notReady' => l.dbRrNotReady,
    'restoreFailed' => l.dbRrRestoreFailed,
    'dumpCorrupt' => l.dbRrCorrupt,
    'sanityFailed' => l.dbRrSanity,
    'timeout' => l.dbRrTimeout,
    'shutdown' => l.dbRrShutdown,
    _ => reason ?? '',
  };
  return detail == null || detail.isEmpty ? base : '$base ($detail)';
}

/// The failure reason of a notification (`reason` or `reason: detail`) → text.
String restoreNotificationReason(AppLocalizations l, String raw) {
  final i = raw.indexOf(': ');
  return i < 0 ? restoreReasonText(l, raw) : restoreReasonText(l, raw.substring(0, i), raw.substring(i + 2));
}

String restoreFailureText(AppLocalizations l, String reason) => switch (reason) {
  'queryFailed' => l.dbRfQueryFailed,
  'notNumeric' => l.dbRfNotNumeric,
  _ => l.dbRfExpectation,
};
