// Texts of the security center's S-2…S-5 sections: scan statuses and reasons, secret sources, decoy states, outside-view
// rules, black box reasons and the notifications of these sections. Pure functions of the localizations; an unknown
// id shows itself.
import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theme/tokens.dart';
import 'security_texts.dart' show securityErrorText;

String _s(Map<String, dynamic> p, String k) => '${p[k] ?? ''}';
int _n(Map<String, dynamic> p, String k) => (p[k] as num?)?.toInt() ?? int.tryParse('${p[k]}') ?? 0;

/// "agent.security.imageTooLarge" and "imageTooLarge" both name the same reason.
String _bare(String code) => code.startsWith('agent.security.') ? code.substring('agent.security.'.length) : code;

// ---- S-2 vulnerabilities ----

String vulnStatusName(AppLocalizations l, String status) => switch (status) {
      'ok' => l.secVulnStatusOk,
      'failed' => l.secVulnStatusFailed,
      'needsCredentials' => l.secVulnStatusNeedsCredentials,
      'notAvailable' => l.secVulnStatusNotAvailable,
      'pending' => l.secVulnStatusPending,
      _ => status,
    };

Color vulnStatusColor(TiphysTokens t, String status) => switch (status) {
      'ok' => t.success,
      'failed' => t.danger,
      'needsCredentials' || 'pending' => t.warning,
      _ => t.textSecondary,
    };

/// The reason behind a status (agent `error` field): the registry for missing credentials, nightOnly / saveLimit for a
/// pending image, a reason id or an agent error code for a failure. null = nothing to add.
String? vulnErrorText(AppLocalizations l, String status, String? error) {
  if (error == null || error.isEmpty) return null;
  if (status == 'needsCredentials') return l.secVulnErrCredentials(error);
  return switch (_bare(error)) {
    'nightOnly' => l.secVulnErrNightOnly,
    'saveLimit' => l.secVulnErrSaveLimit,
    'noSource' => l.secVulnErrNoSource,
    'badOutput' => l.secVulnErrBadOutput,
    'scanFailed' => l.secVulnErrScanFailed,
    'saveFailed' => l.secVulnErrSaveFailed,
    'imageTooLarge' => l.secErrImageTooLarge,
    'knownHostsMissing' => l.secErrKnownHostsMissing,
    'timeout' => l.secErrTimeout,
    'failed' => l.secVulnErrFailed,
    'notFound' => l.secVulnErrNotFound,
    _ => error,
  };
}

String vulnSourceName(AppLocalizations l, String? source) => switch (source) {
      'remote' => l.secVulnSourceRemote,
      'local' => l.secVulnSourceLocal,
      'ssh' => l.secVulnSourceSsh,
      _ => '—',
    };

// ---- S-2 secrets ----

String secretSourceName(AppLocalizations l, String source) => switch (source) {
      'github' => l.secSecretSourceGithub,
      'loki' => l.secSecretSourceLoki,
      'local' => l.secSecretSourceLocal,
      _ => source,
    };

/// An agent error code of a scan run (or an unknown reason) as text.
String secretRunErrorText(AppLocalizations l, String code) => securityErrorText(l, code.startsWith('agent.') ? code : 'agent.security.$code');

String secretRepoErrorText(AppLocalizations l, String error) => switch (error) {
      'cloneFailed' => l.secSecretRepoCloneFailed,
      'scanFailed' => l.secVulnErrScanFailed,
      _ => error,
    };

// ---- S-3 traps ----

String trapKindName(AppLocalizations l, String kind) => kind == 'sshkey' ? l.secTrapKindSshKey : l.secTrapKindEnv;

String trapFileStatusName(AppLocalizations l, String status) => switch (status) {
      'armed' => l.secTrapStatusArmed,
      'noatime' => l.secTrapStatusNoatime,
      'missing' => l.secTrapStatusMissing,
      'error' => l.secTrapStatusError,
      _ => status,
    };

String? trapFileStatusHint(AppLocalizations l, String status) => switch (status) {
      'noatime' => l.secTrapStatusNoatimeHint,
      'missing' => l.secTrapStatusMissingHint,
      'error' => l.secTrapStatusErrorHint,
      _ => null,
    };

Color trapFileStatusColor(TiphysTokens t, String status) => switch (status) {
      'armed' => t.success,
      'noatime' || 'missing' => t.warning,
      _ => t.danger,
    };

// ---- S-5 outside view ----

String exposureRuleTitle(AppLocalizations l, String rule, String target, Map<String, dynamic> p) => switch (rule) {
      'exposure.openPort' => l.secExpRuleOpenPort(_s(p, 'port'), target),
      'exposure.leakPath' => l.secExpRuleLeakPath(_s(p, 'path'), target),
      'exposure.tlsExpiry' => _n(p, 'days') < 0 ? l.secExpRuleTlsExpired(target) : l.secExpRuleTlsExpiry(target, _n(p, 'days')),
      'exposure.noHttps' => l.secExpRuleNoHttps(target),
      'exposure.noHsts' => l.secExpRuleNoHsts(target),
      'exposure.headers' => l.secExpRuleHeaders(target, _s(p, 'missing').replaceAll(',', ', ')),
      'exposure.unreachable' => _s(p, 'what') == 'tls' ? l.secExpRuleUnreachableTls(target) : l.secExpRuleUnreachable(target),
      _ => '$rule · $target',
    };

String? exposureRuleFix(AppLocalizations l, String rule) => switch (rule) {
      'exposure.openPort' => l.secExpFixOpenPort,
      'exposure.leakPath' => l.secExpFixLeakPath,
      'exposure.tlsExpiry' => l.secExpFixTlsExpiry,
      'exposure.noHttps' => l.secExpFixNoHttps,
      'exposure.noHsts' => l.secExpFixNoHsts,
      'exposure.headers' => l.secExpFixHeaders,
      'exposure.unreachable' => l.secExpFixUnreachable,
      _ => null,
    };

// ---- S-4 black box ----

String blackboxModeName(AppLocalizations l, String mode) => switch (mode) {
      'local' => l.secBbModeLocal,
      'push' => l.secBbModePush,
      _ => l.secBbModeOff,
    };

String blackboxReasonText(AppLocalizations l, String? reason) => switch (reason) {
      'sequence' => l.secBbReasonSequence,
      'link' => l.secBbReasonLink,
      'hash' => l.secBbReasonHash,
      'truncated' => l.secBbReasonTruncated,
      'unreadable' => l.secBbReasonUnreadable,
      null || '' => l.secBbReasonUnknown,
      _ => reason,
    };

String blackboxKindName(AppLocalizations l, String kind) => switch (kind) {
      'audit' => l.secBbKindAudit,
      'event' => l.secBbKindEvent,
      'lockdown' => l.secBbKindLockdown,
      _ => kind,
    };

// ---- S-2…S-5 notifications ----

String _sources(AppLocalizations l, String csv) => csv.split(',').where((x) => x.isNotEmpty).map((x) => secretSourceName(l, x)).join(', ');

/// Notification keys of S-2…S-5 → (title, body); null for other keys.
(String, String)? securityMoreNoticeText(AppLocalizations l, String key, Map<String, dynamic> p) => switch (key) {
      'security.vulns' => (l.notifSecVulnsTitle(_s(p, 'image')), l.notifSecVulnsBody(_s(p, 'host'), _n(p, 'critical'), _n(p, 'high'))),
      'security.secretFound' => (l.notifSecSecretTitle(_s(p, 'host')), l.notifSecSecretBody(_n(p, 'count'), _sources(l, _s(p, 'sources')), _s(p, 'where'))),
      'security.trap' => (p['trap'] == 'test' ? l.notifSecTrapTestTitle(_s(p, 'host')) : l.notifSecTrapTitle(_s(p, 'host')), _trapBody(l, p)),
      'blackbox.broken' => (l.notifBbBrokenTitle(_s(p, 'host')), l.notifBbBrokenBody(_n(p, 'at'), blackboxReasonText(l, _s(p, 'reason')))),
      'security.lockdown' => (l.notifSecLockdownTitle(_s(p, 'host')), p['by'] == 'recovery' ? l.notifSecLockdownRecovery : l.notifSecLockdownRemote),
      'security.exposure' => (l.notifSecExposureTitle(_s(p, 'host')), l.notifSecExposureBody(_n(p, 'count'), _s(p, 'targets'))),
      'security.attack' => (l.notifSecAttackTitle(_s(p, 'host')), l.notifSecAttackBody(_n(p, 'count'), _s(p, 'zones'), _n(p, 'blocked'))),
      _ => null,
    };

String _trapBody(AppLocalizations l, Map<String, dynamic> p) => switch (_s(p, 'trap')) {
      'token' => l.notifSecTrapToken(_s(p, 'name'), _s(p, 'from'), _s(p, 'path')),
      'file' => l.notifSecTrapFile(_s(p, 'path')),
      'fileMissing' => l.notifSecTrapFileMissing(_s(p, 'path')),
      'audit' => l.notifSecTrapAudit(_s(p, 'object'), _s(p, 'who'), _s(p, 'how')),
      'db' => l.notifSecTrapDb(_s(p, 'user'), _s(p, 'stream')),
      'test' => l.notifSecTrapTest,
      _ => l.notifSecTrapUnknown,
    };

/// Keys the security center sends that need an urgent channel on the phone.
const securityUrgentKeys = {'security.trap', 'security.secretFound', 'blackbox.broken', 'security.lockdown', 'security.exposure'};
