// Texts of the security center (PLAN.md §15): titles, explanations and fixes of the agent's finding rules, change
// categories, error codes and the notifications. Pure functions of the localizations, shared by the screens, the push
// notifications and agentErrorText. An unknown rule shows its id.
import '../../l10n/gen/app_localizations.dart';

/// Rules of agent/src/security/rules.ts.
const securityRules = [
  'port.exposed', 'ssh.passwordAuth', 'ssh.emptyPasswords', 'ssh.rootLogin', 'ssh.kbdInteractive', 'ssh.x11Forwarding', 'ssh.tcpForwarding',
  'ssh.maxAuthTries', 'users.uid0', 'users.emptyPassword', 'updates.security', 'updates.pending', 'updates.reboot', 'updates.unattendedOff',
  'updates.listsStale', 'firewall.none', 'service.auditd', 'service.apparmor', 'sysctl.weak', 'docker.privileged', 'docker.socket',
  'docker.hostPid', 'docker.hostNetwork', 'files.worldWritable', 'files.agentPerms', //
];

/// agent.security.* codes the app has a text for.
const securityErrorCodes = [
  'timeout', 'reportTooLarge', 'scriptMissing', 'scriptUnsafe', 'collectFailed', 'knownHostsMissing', 'sshFailed', 'unreachable', 'unauthorized', 'busy',
  'agentFailed', 'badReport', 'hostNotFound', 'hostExists', 'tooManyHosts', 'tokenRequired', 'selfPermanent', 'noReport', 'rateLimited', //
];

String _s(Map<String, dynamic> p, String k) => '${p[k] ?? ''}';
int _n(Map<String, dynamic> p, String k) => (p[k] as num?)?.toInt() ?? int.tryParse('${p[k]}') ?? 0;

bool securityRuleKnown(String rule) => securityRules.contains(rule);

String securityRuleTitle(AppLocalizations l, String rule, Map<String, dynamic> p) => switch (rule) {
      'port.exposed' => [l.secRulePortExposed('${_s(p, 'proto')}/${_s(p, 'port')}'), if (p['firewall'] == 'unknown') l.secFirewallUnknownSuffix].join(' '),
      'ssh.passwordAuth' => l.secRuleSshPasswordAuth,
      'ssh.emptyPasswords' => l.secRuleSshEmptyPasswords,
      'ssh.rootLogin' => l.secRuleSshRootLogin(_s(p, 'value')),
      'ssh.kbdInteractive' => l.secRuleSshKbdInteractive,
      'ssh.x11Forwarding' => l.secRuleSshX11Forwarding,
      'ssh.tcpForwarding' => l.secRuleSshTcpForwarding(_s(p, 'value')),
      'ssh.maxAuthTries' => l.secRuleSshMaxAuthTries(_s(p, 'value')),
      'users.uid0' => l.secRuleUsersUid0(_s(p, 'user')),
      'users.emptyPassword' => l.secRuleUsersEmptyPassword(_s(p, 'user')),
      'updates.security' => l.secRuleUpdatesSecurity(_n(p, 'count')),
      'updates.pending' => l.secRuleUpdatesPending(_n(p, 'count')),
      'updates.reboot' => l.secRuleUpdatesReboot(_n(p, 'days')),
      'updates.unattendedOff' => l.secRuleUpdatesUnattendedOff,
      'updates.listsStale' => l.secRuleUpdatesListsStale(_n(p, 'days')),
      'firewall.none' => l.secRuleFirewallNone,
      'service.auditd' => l.secRuleServiceAuditd,
      'service.apparmor' => l.secRuleServiceApparmor,
      'sysctl.weak' => l.secRuleSysctlWeak(_n(p, 'count')),
      'docker.privileged' => l.secRuleDockerPrivileged(_s(p, 'container')),
      'docker.socket' => l.secRuleDockerSocket(_s(p, 'container')),
      'docker.hostPid' => l.secRuleDockerHostPid(_s(p, 'container')),
      'docker.hostNetwork' => l.secRuleDockerHostNetwork(_s(p, 'container')),
      'files.worldWritable' => l.secRuleFilesWorldWritable(_n(p, 'count')),
      'files.agentPerms' => l.secRuleFilesAgentPerms(_s(p, 'path')),
      _ => rule,
    };

/// One-line explanation; null for an unknown rule.
String? securityRuleWhy(AppLocalizations l, String rule, Map<String, dynamic> p) => switch (rule) {
      'port.exposed' => _s(p, 'process').isEmpty ? l.secRulePortExposedWhy(_s(p, 'addr')) : l.secRulePortExposedWhyProc(_s(p, 'process'), _s(p, 'addr')),
      'ssh.passwordAuth' => l.secRuleSshPasswordAuthWhy,
      'ssh.emptyPasswords' => l.secRuleSshEmptyPasswordsWhy,
      'ssh.rootLogin' => l.secRuleSshRootLoginWhy,
      'ssh.kbdInteractive' => l.secRuleSshKbdInteractiveWhy,
      'ssh.x11Forwarding' => l.secRuleSshX11ForwardingWhy,
      'ssh.tcpForwarding' => l.secRuleSshTcpForwardingWhy,
      'ssh.maxAuthTries' => l.secRuleSshMaxAuthTriesWhy,
      'users.uid0' => l.secRuleUsersUid0Why,
      'users.emptyPassword' => l.secRuleUsersEmptyPasswordWhy,
      'updates.security' => l.secRuleUpdatesSecurityWhy,
      'updates.pending' => l.secRuleUpdatesPendingWhy,
      'updates.reboot' => l.secRuleUpdatesRebootWhy,
      'updates.unattendedOff' => l.secRuleUpdatesUnattendedOffWhy,
      'updates.listsStale' => l.secRuleUpdatesListsStaleWhy,
      'firewall.none' => l.secRuleFirewallNoneWhy(_n(p, 'exposed')),
      'service.auditd' => l.secRuleServiceAuditdWhy,
      'service.apparmor' => l.secRuleServiceApparmorWhy,
      'sysctl.weak' => l.secRuleSysctlWeakWhy(_s(p, 'keys').replaceAll(',', ', ')),
      'docker.privileged' => l.secRuleDockerPrivilegedWhy,
      'docker.socket' => l.secRuleDockerSocketWhy,
      'docker.hostPid' => l.secRuleDockerHostPidWhy,
      'docker.hostNetwork' => l.secRuleDockerHostNetworkWhy,
      'files.worldWritable' => l.secRuleFilesWorldWritableWhy(_s(p, 'example')),
      'files.agentPerms' => l.secRuleFilesAgentPermsWhy(_s(p, 'mode')),
      _ => null,
    };

/// Suggested fix; null for an unknown rule.
String? securityRuleFix(AppLocalizations l, String rule) => switch (rule) {
      'port.exposed' => l.secRulePortExposedFix,
      'ssh.passwordAuth' => l.secRuleSshPasswordAuthFix,
      'ssh.emptyPasswords' => l.secRuleSshEmptyPasswordsFix,
      'ssh.rootLogin' => l.secRuleSshRootLoginFix,
      'ssh.kbdInteractive' => l.secRuleSshKbdInteractiveFix,
      'ssh.x11Forwarding' => l.secRuleSshX11ForwardingFix,
      'ssh.tcpForwarding' => l.secRuleSshTcpForwardingFix,
      'ssh.maxAuthTries' => l.secRuleSshMaxAuthTriesFix,
      'users.uid0' => l.secRuleUsersUid0Fix,
      'users.emptyPassword' => l.secRuleUsersEmptyPasswordFix,
      'updates.security' => l.secRuleUpdatesSecurityFix,
      'updates.pending' => l.secRuleUpdatesPendingFix,
      'updates.reboot' => l.secRuleUpdatesRebootFix,
      'updates.unattendedOff' => l.secRuleUpdatesUnattendedOffFix,
      'updates.listsStale' => l.secRuleUpdatesListsStaleFix,
      'firewall.none' => l.secRuleFirewallNoneFix,
      'service.auditd' => l.secRuleServiceAuditdFix,
      'service.apparmor' => l.secRuleServiceApparmorFix,
      'sysctl.weak' => l.secRuleSysctlWeakFix,
      'docker.privileged' => l.secRuleDockerPrivilegedFix,
      'docker.socket' => l.secRuleDockerSocketFix,
      'docker.hostPid' => l.secRuleDockerHostPidFix,
      'docker.hostNetwork' => l.secRuleDockerHostNetworkFix,
      'files.worldWritable' => l.secRuleFilesWorldWritableFix,
      'files.agentPerms' => l.secRuleFilesAgentPermsFix,
      _ => null,
    };

/// Name of a section the audit could not produce (`report.unavailable`); an unknown id is shown as it is.
String securitySectionName(AppLocalizations l, String id) => switch (id) {
      'listen' => l.secSecListen,
      'nft' => l.secSecNft,
      'sshd' => l.secSecSshd,
      'passwords' => l.secSecPasswords,
      'sudoers' => l.secSecSudoers,
      'authkeys' => l.secSecAuthkeys,
      'cron' => l.secSecCron,
      'timers' => l.secSecTimers,
      'autostart' => l.secSecAutostart,
      'logins' => l.secSecLogins,
      'docker' => l.secSecDocker,
      'suid' => l.secSecSuid,
      'worldwritable' => l.secSecWorldwritable,
      'agentfiles' => l.secSecAgentfiles,
      'users' => l.secSecUsers,
      'groups' => l.secSecGroups,
      'updates' => l.secSecUpdates,
      'services' => l.secSecServices,
      'sysctl' => l.secSecSysctl,
      'meta' => l.secSecMeta,
      _ => id,
    };

const securitySectionIds = ['listen', 'nft', 'sshd', 'passwords', 'sudoers', 'authkeys', 'cron', 'timers', 'autostart', 'logins', 'docker', 'suid', 'worldwritable', 'agentfiles', 'users', 'groups', 'updates', 'services', 'sysctl', 'meta'];

String securityCategoryName(AppLocalizations l, String c) => switch (c) {
      'ports' => l.secCatPorts,
      'users' => l.secCatUsers,
      'passwords' => l.secCatPasswords,
      'sudoers' => l.secCatSudoers,
      'authKeys' => l.secCatAuthKeys,
      'cron' => l.secCatCron,
      'timers' => l.secCatTimers,
      'autostart' => l.secCatAutostart,
      'sshd' => l.secCatSshd,
      'containers' => l.secCatContainers,
      'suid' => l.secCatSuid,
      'services' => l.secCatServices,
      _ => c,
    };

String securityKindName(AppLocalizations l, String kind) => switch (kind) {
      'added' => l.secKindAdded,
      'removed' => l.secKindRemoved,
      'changed' => l.secKindChanged,
      _ => kind,
    };

String securitySeverityName(AppLocalizations l, String s) => switch (s) {
      'critical' => l.secSeverityCritical,
      'high' => l.secSeverityHigh,
      'medium' => l.secSeverityMedium,
      'low' => l.secSeverityLow,
      _ => s,
    };

String securityScopeName(AppLocalizations l, String scope) => switch (scope) {
      'wildcard' || 'public' => l.secScopeExposed,
      'tailscale' => l.secScopeTailscale,
      'loopback' => l.secScopeLoopback,
      'private' => l.secScopePrivate,
      'linklocal' => l.secScopeLinklocal,
      _ => scope,
    };

String securityRoleName(AppLocalizations l, String role) => role == 'desktop' ? l.secRoleDesktop : l.secRoleServer;

String securitySourceName(AppLocalizations l, String source) => switch (source) {
      'ssh' => l.secSourceSsh,
      'agent' => l.secSourceAgent,
      _ => l.secSourceLocal,
    };

/// agent.security.* → text (an unknown code shows the generic error with the code).
String securityErrorText(AppLocalizations l, String code, [Map<String, dynamic> params = const {}]) => switch (code) {
      'agent.security.timeout' => l.secErrTimeout,
      'agent.security.reportTooLarge' => l.secErrReportTooLarge,
      'agent.security.scriptMissing' => l.secErrScriptMissing,
      'agent.security.scriptUnsafe' => l.secErrScriptUnsafe,
      'agent.security.collectFailed' => l.secErrCollectFailed,
      'agent.security.knownHostsMissing' => l.secErrKnownHostsMissing,
      'agent.security.sshFailed' => l.secErrSshFailed,
      'agent.security.unreachable' => l.secErrUnreachable,
      'agent.security.unauthorized' => l.secErrUnauthorized,
      'agent.security.busy' => l.secErrBusy,
      'agent.security.agentFailed' => l.secErrAgentFailed,
      'agent.security.badReport' => l.secErrBadReport,
      'agent.security.hostNotFound' => l.secErrHostNotFound,
      'agent.security.hostExists' => l.secErrHostExists,
      'agent.security.tooManyHosts' => l.secErrTooManyHosts,
      'agent.security.tokenRequired' => l.secErrTokenRequired,
      'agent.security.selfPermanent' => l.secErrSelfPermanent,
      'agent.security.noReport' => l.secErrNoReport,
      'agent.security.rateLimited' => l.secErrRateLimited,
      _ => '${l.commonError} ($code)',
    };

/// Notification keys of the security center → (title, body); null for other keys.
(String, String)? securityNoticeText(AppLocalizations l, String key, Map<String, dynamic> p) => switch (key) {
      'security.change' => (
          p['severity'] == 'critical' ? l.notifSecChangeCriticalTitle(_s(p, 'host')) : l.notifSecChangeTitle(_s(p, 'host')),
          l.notifSecChangeBody(_n(p, 'count'), _s(p, 'categories').split(',').where((c) => c.isNotEmpty).map((c) => securityCategoryName(l, c)).join(', ')),
        ),
      'security.accepted' => (l.notifSecAcceptedTitle(_s(p, 'host')), l.notifSecAcceptedBody(_n(p, 'count'))),
      'security.unreachable' => (l.notifSecUnreachableTitle(_s(p, 'host')), l.notifSecUnreachableBody(_n(p, 'hours'), securityErrorText(l, _s(p, 'code')))),
      'security.reachable' => (l.notifSecReachableTitle(_s(p, 'host')), ''),
      _ => null,
    };
