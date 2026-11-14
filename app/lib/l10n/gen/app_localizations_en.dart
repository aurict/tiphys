// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Tiphys';

  @override
  String get tabHome => 'Home';

  @override
  String get tabClaude => 'Claude';

  @override
  String get tabTerminal => 'Terminal';

  @override
  String get tabFiles => 'Files';

  @override
  String get tabSystem => 'System';

  @override
  String get homeInfra => 'Infrastructure';

  @override
  String homeOnlineCount(int online, int total) {
    return '$online/$total online';
  }

  @override
  String get homeNoHosts => 'No hosts yet';

  @override
  String get homeAddHost => 'Add a host in Settings';

  @override
  String homeClaudeSessions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'sessions',
      one: 'session',
      zero: 'no sessions',
    );
    return '$_temp0';
  }

  @override
  String homeClaudeWaiting(int count) {
    return '$count waiting';
  }

  @override
  String get homeNewClaudeSession => 'New Claude session';

  @override
  String homeCpu(String percent) {
    return 'CPU $percent';
  }

  @override
  String homeRam(String percent) {
    return 'RAM $percent';
  }

  @override
  String get homeQuickAccess => 'Quick access';

  @override
  String get homeOpenInBrowser => 'in browser';

  @override
  String homeTabsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tabs',
      one: '1 tab',
    );
    return '$_temp0';
  }

  @override
  String get homeLive => 'live';

  @override
  String get homeLastHour => 'CPU · 1 h';

  @override
  String get homeNotConnected => 'not connected';

  @override
  String get homeSearch => 'Search';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonRetry => 'Try again';

  @override
  String get commonSave => 'Save';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonDelete => 'Delete';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonEdit => 'Edit';

  @override
  String get commonDone => 'Done';

  @override
  String get commonClose => 'Close';

  @override
  String get commonCopy => 'Copy';

  @override
  String get commonCopied => 'Copied';

  @override
  String get commonShare => 'Share';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonContinue => 'Continue';

  @override
  String get commonTest => 'Test connection';

  @override
  String get commonTesting => 'Testing…';

  @override
  String get commonTestOk => 'Connection works';

  @override
  String commonTestFailed(String reason) {
    return 'Connection failed: $reason';
  }

  @override
  String get commonOptional => 'optional';

  @override
  String get commonRequired => 'Required';

  @override
  String get commonNone => 'None';

  @override
  String get commonEmpty => 'Nothing here yet';

  @override
  String get commonError => 'Something went wrong';

  @override
  String get commonUnsaved => 'You have unsaved changes';

  @override
  String get commonDiscard => 'Discard';

  @override
  String get commonOn => 'On';

  @override
  String get commonOff => 'Off';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsHosts => 'Hosts';

  @override
  String get settingsHostsHint =>
      'Servers and the PC: address, SSH, agent, wake';

  @override
  String get settingsKeys => 'Keys & secrets';

  @override
  String get settingsKeysHint => 'SSH keys, API tokens, passwords';

  @override
  String get settingsClaude => 'Claude';

  @override
  String get settingsClaudeHint =>
      'Agent, defaults, profiles, favourite folders';

  @override
  String get settingsIntegrations => 'Integrations';

  @override
  String get settingsIntegrationsHint =>
      'Grafana, Dozzle, Homepage, Uptime Kuma, ntfy, Scriberr';

  @override
  String get settingsTerminal => 'Terminal';

  @override
  String get settingsTerminalHint => 'Font, keys bar, snippets';

  @override
  String get settingsFiles => 'Files';

  @override
  String get settingsFilesHint => 'Bookmarks, hidden files';

  @override
  String get settingsQuickActions => 'Quick actions';

  @override
  String get settingsQuickActionsHint => 'Your own one-tap commands';

  @override
  String get settingsHome => 'Home screen';

  @override
  String get settingsHomeHint => 'Cards and their order';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsAppearanceHint => 'Theme and language';

  @override
  String get settingsSecurity => 'Security';

  @override
  String get settingsSecurityHint => 'Biometrics, PIN, auto-lock';

  @override
  String get settingsProfile => 'Profile file';

  @override
  String get settingsProfileHint => 'Import, export, reset';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsNotificationsHint => 'What to be told about';

  @override
  String get appearanceTheme => 'Theme';

  @override
  String get appearanceThemeSystem => 'System';

  @override
  String get appearanceThemeLight => 'Light';

  @override
  String get appearanceThemeDark => 'Dark';

  @override
  String get appearanceLanguage => 'Language';

  @override
  String get appearanceLanguageSystem => 'System language';

  @override
  String get appearanceLanguageTr => 'Türkçe';

  @override
  String get appearanceLanguageEn => 'English';

  @override
  String get hostsEmpty => 'No hosts. Add your PC and servers.';

  @override
  String get hostAdd => 'Add host';

  @override
  String get hostEdit => 'Edit host';

  @override
  String get hostId => 'ID';

  @override
  String get hostIdHint => 'lowercase, e.g. atlas';

  @override
  String get hostName => 'Name';

  @override
  String get hostColor => 'Colour';

  @override
  String get hostAddress => 'Address';

  @override
  String get hostAddressHint => 'Tailscale name or IP';

  @override
  String get hostSsh => 'SSH';

  @override
  String get hostSshPort => 'Port';

  @override
  String get hostSshUser => 'User';

  @override
  String get hostSshAuth => 'Sign-in';

  @override
  String get hostSshAuthKey => 'SSH key';

  @override
  String get hostSshAuthPassword => 'Password';

  @override
  String get hostSshKey => 'Key';

  @override
  String get hostSshPassword => 'Password';

  @override
  String get hostTmux => 'tmux session';

  @override
  String get hostAgent => 'Tiphys agent';

  @override
  String get hostAgentUrl => 'Agent address';

  @override
  String get hostAgentToken => 'Agent token';

  @override
  String get hostAgentNone => 'No agent on this host';

  @override
  String get hostWake => 'Wake-on-LAN';

  @override
  String get hostWakeMac => 'MAC address';

  @override
  String get hostWakeVia => 'Send from';

  @override
  String get hostTags => 'Tags';

  @override
  String hostDeleteConfirm(String name) {
    return 'Delete $name? Things that use this host will lose it.';
  }

  @override
  String get keysEmpty => 'No keys or secrets yet.';

  @override
  String get keysSshKeys => 'SSH keys';

  @override
  String get keysTokens => 'Tokens and passwords';

  @override
  String get keyImportFile => 'Import from file';

  @override
  String get keyPaste => 'Paste a key';

  @override
  String get keyGenerate => 'Generate on this phone';

  @override
  String get keyLabel => 'Label';

  @override
  String get keyPrivate => 'Private key';

  @override
  String get keyPassphrase => 'Passphrase';

  @override
  String get keyPublic => 'Public key';

  @override
  String get keyCopyPublic => 'Copy public key';

  @override
  String get keyInstallOnHost => 'Add to a host\'s authorized_keys';

  @override
  String get keyInvalid => 'This doesn\'t look like an SSH private key';

  @override
  String get keyGenerated => 'Key generated';

  @override
  String get secretAdd => 'Add secret';

  @override
  String get secretValue => 'Value';

  @override
  String get secretStoredSafely =>
      'Stored in the Android Keystore. Never written to the profile file in plain text.';

  @override
  String secretMissing(String id) {
    return 'Missing secret: $id';
  }

  @override
  String get profileExport => 'Export';

  @override
  String get profileExportPlain => 'Without secrets';

  @override
  String get profileExportPlainHint =>
      'Safe to share. Keys and tokens are left out.';

  @override
  String get profileExportEncrypted => 'Encrypted backup';

  @override
  String get profileExportEncryptedHint =>
      'Keys and tokens included, encrypted with a passphrase.';

  @override
  String get profileImport => 'Import';

  @override
  String get profileImportHint => 'Choose a .tiphys.json file';

  @override
  String get profileReset => 'Reset everything';

  @override
  String get profileResetConfirm =>
      'Delete all settings and secrets on this phone?';

  @override
  String get profilePassphrase => 'Passphrase';

  @override
  String get profilePassphraseRepeat => 'Repeat passphrase';

  @override
  String get profilePassphraseMismatch => 'Passphrases don\'t match';

  @override
  String get profilePassphraseShort => 'At least 10 characters';

  @override
  String get profilePassphraseWrong => 'Wrong passphrase or damaged file';

  @override
  String get profileExported => 'Profile exported';

  @override
  String get profileImported => 'Profile imported';

  @override
  String get profilePreviewTitle => 'Review changes';

  @override
  String get profilePreviewAdded => 'Will be added';

  @override
  String get profilePreviewChanged => 'Will change';

  @override
  String get profilePreviewRemoved => 'Will be removed';

  @override
  String get profilePreviewUnchanged => 'No changes';

  @override
  String get profileModeMerge => 'Merge';

  @override
  String get profileModeMergeHint =>
      'Same IDs are overwritten, new ones are added, nothing is removed.';

  @override
  String get profileModeReplace => 'Replace all';

  @override
  String get profileModeReplaceHint =>
      'Everything becomes exactly what is in the file.';

  @override
  String get profileMissingSecrets => 'Secrets you need to enter again';

  @override
  String get profileErrorFormat => 'This is not a Tiphys profile';

  @override
  String profileErrorNewer(int version) {
    return 'This file was made by a newer Tiphys (schema $version)';
  }

  @override
  String profileErrorInvalid(String details) {
    return 'The file has errors: $details';
  }

  @override
  String get profileErrorJson => 'The file is not valid JSON';

  @override
  String get securityBiometric => 'Unlock with fingerprint';

  @override
  String get securityPin => 'PIN';

  @override
  String get securityPinSet => 'Set PIN';

  @override
  String get securityPinChange => 'Change PIN';

  @override
  String get securityPinEnter => 'Enter PIN';

  @override
  String get securityPinNew => 'New PIN';

  @override
  String get securityPinRepeat => 'Repeat PIN';

  @override
  String get securityPinWrong => 'Wrong PIN';

  @override
  String get securityPinShort => 'At least 6 digits';

  @override
  String get securityAutoLock => 'Auto-lock';

  @override
  String securityAutoLockSeconds(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: 'After $seconds s',
      zero: 'Immediately',
    );
    return '$_temp0';
  }

  @override
  String get lockTitle => 'Tiphys is locked';

  @override
  String get lockUnlock => 'Unlock';

  @override
  String get lockBiometricReason => 'Unlock Tiphys';

  @override
  String get homeCardsInfra => 'Infrastructure';

  @override
  String get homeCardsClaude => 'Claude';

  @override
  String get homeCardsSystem => 'PC status';

  @override
  String get homeCardsGrafana => 'Grafana';

  @override
  String get homeCardsDozzle => 'Dozzle';

  @override
  String get homeCardsQuickAccess => 'Quick access';

  @override
  String comingInPhase(int phase) {
    return 'Coming in phase $phase';
  }

  @override
  String get relativeNow => 'just now';

  @override
  String relativeMinutes(int count) {
    return '$count min ago';
  }

  @override
  String relativeHours(int count) {
    return '$count h ago';
  }

  @override
  String relativeDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: 'yesterday',
    );
    return '$_temp0';
  }

  @override
  String get claudeAgentHost => 'Agent that runs Claude';

  @override
  String get claudeModel => 'Model';

  @override
  String get claudeEffort => 'Thinking effort';

  @override
  String get claudePermissionMode => 'Permission mode';

  @override
  String get claudeModeBypass => 'Don\'t ask (bypass permissions)';

  @override
  String get claudeModeAcceptEdits => 'Accept edits, ask for commands';

  @override
  String get claudeModeDefault => 'Ask every time';

  @override
  String get claudeModePlan => 'Plan first';

  @override
  String get claudeProfiles => 'Profiles';

  @override
  String get claudeProfilesHint => 'One per line: id = config folder';

  @override
  String get claudeFavoriteFolders => 'Favourite folders';

  @override
  String get claudePinnedCommands => 'Pinned slash commands';

  @override
  String durationSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String get filesBookmarks => 'Bookmarks';

  @override
  String get filesBookmarksHint => 'One per line: host:path';

  @override
  String get filesShowHidden => 'Show hidden files';

  @override
  String get hostWakeViaHint =>
      'The wake packet must be sent from the PC\'s own local network. \"This phone\" works only while the phone is on that Wi-Fi.';

  @override
  String get hostWakeViaPhone => 'This phone (same Wi-Fi)';

  @override
  String integrationAdd(String name) {
    return 'Add $name';
  }

  @override
  String get integrationOthers => 'Others';

  @override
  String get integrationNotSet => 'not set up';

  @override
  String get integrationToken => 'Use a token';

  @override
  String get integrationServiceAccountToken => 'Service account token';

  @override
  String get integrationAccessToken => 'Access token';

  @override
  String get integrationApiKey => 'API key';

  @override
  String get integrationLogin => 'Sign-in required';

  @override
  String get integrationDefaults => 'Defaults';

  @override
  String get integrationDefaultDashboard => 'Default dashboard UID';

  @override
  String get integrationRefreshSeconds => 'Refresh (s)';

  @override
  String get integrationRange => 'Time range';

  @override
  String get integrationBrowserUrl => 'Address for the browser';

  @override
  String get integrationReadVia => 'Read through agent on';

  @override
  String get integrationServicesFile => 'services.yaml path';

  @override
  String get integrationOpenInApp => 'Open services inside the app';

  @override
  String get integrationNeedsAgentHost =>
      'Add a host with a Tiphys agent first';

  @override
  String get integrationDeleteConfirm => 'Remove this integration?';

  @override
  String get notifyClaudeDone => 'When a session finishes';

  @override
  String get notifyClaudeWaiting => 'When it needs my approval';

  @override
  String get notifyClaudeError => 'When it fails';

  @override
  String get notifySiteDown => 'Site outages';

  @override
  String get notifyPcOffline => 'PC goes offline';

  @override
  String get notifyServiceDown => 'A service crashes';

  @override
  String get notifyGrafana => 'Grafana alerts';

  @override
  String get notifyDiskFull => 'Disk almost full warning at';

  @override
  String get notifyLongCommand => 'Tell me when a long command finishes';

  @override
  String get ntfyTopics => 'Topics to follow';

  @override
  String get ntfyTopicsHint =>
      'Comma separated. e.g. siteler for Uptime Kuma alerts';

  @override
  String get quickActionCommand => 'Command';

  @override
  String get quickActionConfirm => 'Ask before running';

  @override
  String get scriberrAutoDetect => 'Detect automatically';

  @override
  String get scriberrModel => 'Model';

  @override
  String get scriberrModelSmall => 'small (fast)';

  @override
  String get scriberrModelLarge => 'large-v3 (accurate)';

  @override
  String get secretNeedsValue => 'missing';

  @override
  String get secretUnused => 'not used by any setting';

  @override
  String get terminalFontSize => 'Font size';

  @override
  String get terminalExtraKeys => 'Extra keys bar';

  @override
  String get terminalExtraKeysHint =>
      'Space separated: esc tab ctrl alt up down left right | ~ /';

  @override
  String get terminalSnippets => 'Snippets';

  @override
  String get terminalSnippetsHint =>
      'One per line: name | command | host (optional)';

  @override
  String get terminalThemeNote => 'Terminal colours follow the app theme.';

  @override
  String get uptimeInterval => 'Check interval (s)';

  @override
  String get uptimeAlertAfter => 'Alert after down for (s)';

  @override
  String get uptimeCertDays => 'Warn days before SSL expiry';

  @override
  String get uptimeCredentialsOnAgent =>
      'The Uptime Kuma login stays on the agent; the phone never stores it.';

  @override
  String get uptimeNotifyRecovery => 'Tell me when a site is back';

  @override
  String get sshNoSsh => 'SSH is not set up for this host';

  @override
  String get sshUnreachable => 'Host unreachable (is Tailscale on?)';

  @override
  String get sshAuthFailed => 'Sign-in rejected: check the key or password';

  @override
  String get sshTimeout => 'Connection timed out';

  @override
  String get sshHostKeyChanged =>
      'The server key changed! Connection stopped for safety.';

  @override
  String sshConnecting(String name) {
    return 'Connecting to $name…';
  }

  @override
  String get sshDisconnected =>
      'Disconnected. The tmux session keeps running on the server.';

  @override
  String get sshReconnect => 'Reconnect';

  @override
  String terminalOpenOn(String name) {
    return 'New terminal on $name';
  }

  @override
  String get terminalPickHost => 'Pick a host above to open a terminal.';

  @override
  String get terminalNoSshHosts =>
      'No host with SSH yet. Add one in Settings › Hosts.';

  @override
  String get filesUpload => 'Upload here';

  @override
  String filesUploaded(String name) {
    return 'Uploaded $name';
  }

  @override
  String get filesUp => 'Parent folder';

  @override
  String get filesTerminalHere => 'Terminal here';

  @override
  String get filesClaudeHere => 'Claude here';

  @override
  String get filesNewFolder => 'New folder';

  @override
  String get filesPasteHere => 'Paste here';

  @override
  String get filesEmptyFolder => 'This folder is empty';

  @override
  String get filesPreview => 'Preview';

  @override
  String get filesDownload => 'Download / share';

  @override
  String get filesRename => 'Rename';

  @override
  String get filesCopy => 'Copy';

  @override
  String get filesMove => 'Move';

  @override
  String get filesTrash => 'Move to trash';

  @override
  String filesTrashConfirm(String name) {
    return 'Move $name to the trash? You can restore it from the desktop trash.';
  }

  @override
  String get filesTrashed => 'Moved to trash';

  @override
  String get filesMore => 'More';

  @override
  String get filesBinary => 'Binary file: use download to open it';

  @override
  String get keyNeedsPassphrase =>
      'This key is protected; enter its passphrase';

  @override
  String keyInstalled(String name) {
    return 'Key added to $name';
  }

  @override
  String keyDeleteConfirm(String name) {
    return 'Delete the key $name from this phone?';
  }

  @override
  String get systemMonitoring => 'Monitoring';

  @override
  String get systemSites => 'Sites (Uptime Kuma)';

  @override
  String systemUptime(int days, int hours) {
    return 'up $days d $hours h';
  }

  @override
  String get systemDisk => 'Disk';

  @override
  String get systemPower => 'Power';

  @override
  String get systemWake => 'Wake up (Wake-on-LAN)';

  @override
  String systemWakeSent(String name) {
    return 'Wake packet sent to $name';
  }

  @override
  String get systemSuspend => 'Sleep';

  @override
  String get systemReboot => 'Restart';

  @override
  String get systemPowerOff => 'Shut down';

  @override
  String systemPowerConfirm(String action, String host) {
    return '$action $host?';
  }

  @override
  String systemPowerSent(String action) {
    return 'Sent: $action';
  }

  @override
  String get systemServices => 'Services';

  @override
  String get systemScopeUser => 'User';

  @override
  String get systemScopeSystem => 'System';

  @override
  String get systemLogs => 'Logs';

  @override
  String get systemRestart => 'Restart';

  @override
  String get systemStart => 'Start';

  @override
  String get systemStop => 'Stop';

  @override
  String get systemDone => 'Done';

  @override
  String systemShowAll(int count) {
    return 'Show all ($count)';
  }

  @override
  String get agentUnreachable =>
      'Agent unreachable (is the PC on and Tailscale connected?)';

  @override
  String get agentTls => 'Secure connection failed';

  @override
  String get agentBadToken => 'The agent rejected this phone; pair again';

  @override
  String get agentWrongTailnetUser =>
      'This Tailscale account is not allowed on the agent';

  @override
  String get agentPermissionDenied =>
      'Not permitted (system services need root)';

  @override
  String get agentFeatureOff => 'This feature is turned off on the agent';

  @override
  String get pairScanTitle => 'Pair with agent';

  @override
  String get pairScanHint =>
      'On the server run: tiphys-agent pair --name \"Phone\" and scan the QR code';

  @override
  String get pairNotTiphys => 'This is not a Tiphys pairing code';

  @override
  String get pairWithQr => 'Pair with QR code';

  @override
  String get agentSettings => 'Agent settings';

  @override
  String get agentFeatures => 'Features';

  @override
  String get agentRestartHint =>
      'Feature changes apply after the agent restarts.';

  @override
  String get agentRestartRequired =>
      'Saved. Restart the agent to apply feature changes.';

  @override
  String get agentAllowedRoots => 'Allowed folders';

  @override
  String get agentAllowedRootsHint =>
      'One per line. Claude and file actions stay inside these.';

  @override
  String get agentDevices => 'Paired devices';

  @override
  String get agentRevoke => 'Revoke';

  @override
  String agentRevokeConfirm(String name) {
    return 'Revoke access for $name?';
  }

  @override
  String get agentLockAll => 'Lock everything';

  @override
  String get agentLockAllHint =>
      'Revokes every paired device, including this phone. Pair again on the server to get back in.';

  @override
  String get agentLockAllConfirm =>
      'Revoke all devices on this agent, including this phone?';

  @override
  String get agentFeatSystem => 'System metrics';

  @override
  String get agentFeatServices => 'systemd services';

  @override
  String get agentFeatWatch => 'Watch hosts (offline alerts)';

  @override
  String get claudeLive => 'Open sessions';

  @override
  String get claudeHistory => 'History';

  @override
  String get claudeContinue => 'Continue';

  @override
  String get claudeStart => 'Start';

  @override
  String get claudeFolder => 'Folder';

  @override
  String get claudeChooseFolder => 'Choose';

  @override
  String get claudePromptHint => 'What should Claude do?';

  @override
  String get claudeQueueHint => 'Add a message to the queue…';

  @override
  String get claudeModeBypassShort => 'Don\'t ask';

  @override
  String get claudeModeAcceptShort => 'Accept edits';

  @override
  String get claudeModeDefaultShort => 'Ask';

  @override
  String get claudeStatusRunning => 'working';

  @override
  String get claudeStatusWaiting => 'waiting for you';

  @override
  String get claudeStatusIdle => 'done';

  @override
  String get claudeStatusError => 'error';

  @override
  String get claudeStatusStopped => 'closed';

  @override
  String get claudeThinking => 'Thinking';

  @override
  String claudePermissionTitle(String tool) {
    return 'Claude wants to use $tool';
  }

  @override
  String get claudeAllow => 'Allow';

  @override
  String get claudeDeny => 'Deny';

  @override
  String get claudeAllowed => 'Allowed';

  @override
  String get claudeDenied => 'Denied';

  @override
  String claudeResultLine(int turns, int seconds) {
    return '$turns turns · $seconds s';
  }

  @override
  String get claudeWorking => 'Claude is working…';

  @override
  String get claudeSlashCommands => 'Slash commands';

  @override
  String get claudeStop => 'Stop';

  @override
  String get claudeSend => 'Send';

  @override
  String get claudeEndSession => 'End session';

  @override
  String get integrationAuthFailed => 'Sign-in rejected (check the token)';

  @override
  String get siteUp => 'Up';

  @override
  String get siteDown => 'Down';

  @override
  String get siteMaintenance => 'Maintenance';

  @override
  String get sitePaused => 'Paused';

  @override
  String get sitePending => 'Pending';

  @override
  String sitesAllUp(int count) {
    return 'All $count sites are up';
  }

  @override
  String sitesSomeDown(int count) {
    return '$count down';
  }

  @override
  String get siteAdd => 'Add site';

  @override
  String siteDeleteConfirm(String name) {
    return 'Stop monitoring $name? Its history is deleted too.';
  }

  @override
  String get sitePause => 'Pause';

  @override
  String get siteResume => 'Resume';

  @override
  String get sitePing => 'Response';

  @override
  String get sitePingChart => 'Response time chart';

  @override
  String get siteIncidents => 'Outages and recoveries';

  @override
  String get siteNoIncidents => 'No outages recorded';

  @override
  String get siteType => 'Check type';

  @override
  String get siteKeyword => 'Keyword';

  @override
  String get siteNotifyNote =>
      'Down and back-up alerts go to your phone through ntfy (topic: siteler).';

  @override
  String get daysShort => 'd';

  @override
  String get hoursShort => 'h';

  @override
  String get dozzlePause => 'Pause';

  @override
  String get dozzleResume => 'Resume';

  @override
  String dozzleBuffered(int count) {
    return '$count new lines waiting';
  }

  @override
  String get dozzleNoLogs => 'No log lines';

  @override
  String get homepageOpenReal => 'Open Homepage in the browser';

  @override
  String homepageDown(String names) {
    return 'Not responding: $names';
  }

  @override
  String get grafanaAll => 'All';

  @override
  String grafanaOpenPanel(String type) {
    return '$type panel: open in browser';
  }

  @override
  String get dozzleRunning => 'running';

  @override
  String get dozzleStopped => 'stopped or unhealthy';

  @override
  String get notifClaudeDoneTitle => 'Claude finished';

  @override
  String get notifClaudeWaitingTitle => 'Claude needs your approval';

  @override
  String notifClaudeWaitingBody(String title, String tool) {
    return '$title · wants to use $tool';
  }

  @override
  String get notifClaudeErrorTitle => 'Claude stopped with an error';

  @override
  String notifHostOfflineTitle(String host) {
    return '$host is offline';
  }

  @override
  String notifHostOfflineBody(int minutes) {
    return 'No answer for $minutes min';
  }

  @override
  String notifHostOnlineTitle(String host) {
    return '$host is back online';
  }

  @override
  String get notifTestTitle => 'Tiphys test notification';

  @override
  String get pushThisPhone => 'This phone';

  @override
  String get pushEnable => 'Turn on notifications';

  @override
  String get pushEnabled => 'Notifications are on';

  @override
  String get pushNoDistributor =>
      'Install the ntfy app first, set its default server to your own ntfy server (e.g. :2586) and sign in. Tiphys then receives notifications through it, without Google.';

  @override
  String get pushChooseDistributor => 'Deliver through';

  @override
  String pushRegistered(String hosts) {
    return 'Registered with: $hosts';
  }

  @override
  String get pushSendTest => 'Send a test notification';

  @override
  String get pushDisable => 'Turn off';

  @override
  String get pushSitesTopic =>
      'Site alerts (Uptime Kuma) come to the ntfy app directly: subscribe to the siteler topic there.';

  @override
  String get pushOpenNtfy => 'Subscribe in ntfy';

  @override
  String get grafanaNoAlerts => 'No active alerts';

  @override
  String get grafanaFiring => 'Firing';

  @override
  String get grafanaPending => 'Pending';

  @override
  String get grafanaNoData => 'No data';

  @override
  String get grafanaNormal => 'Normal';

  @override
  String get agentPathNotAllowed =>
      'This folder is outside the agent\'s allowed roots';

  @override
  String get auditEmpty => 'No actions recorded yet';

  @override
  String get claudeAttachImage => 'Attach photo';

  @override
  String get claudeRemoveImage => 'Remove photo';

  @override
  String claudeUsageSemantics(String usage) {
    return 'Usage: $usage';
  }

  @override
  String get clipboardCopiedPhone => 'Copied to phone clipboard';

  @override
  String get clipboardCopyPhone => 'Copy to phone';

  @override
  String get clipboardFromPc => 'Get from PC';

  @override
  String get clipboardPastePhone => 'Paste from phone';

  @override
  String get clipboardPcContent => 'PC clipboard';

  @override
  String get clipboardSent => 'Sent to PC clipboard';

  @override
  String get clipboardToPc => 'Send to PC';

  @override
  String get commonCreate => 'Create';

  @override
  String get commonNothingFound => 'Nothing found';

  @override
  String durationHours(int n) {
    return '$n h';
  }

  @override
  String durationMinutes(int n) {
    return '$n min';
  }

  @override
  String get editorChangedOnDisk =>
      'The file changed on the computer since you opened it. Overwrite it with your version?';

  @override
  String get editorDiscard => 'Discard';

  @override
  String get editorDiscardChanges => 'Discard unsaved changes?';

  @override
  String get editorNotText =>
      'This file is not text (or is larger than 1 MB), so it can\'t be edited here.';

  @override
  String get editorOverwrite => 'Overwrite';

  @override
  String get editorSaved => 'Saved';

  @override
  String get editorWrap => 'Wrap lines';

  @override
  String get filesEdit => 'Edit';

  @override
  String get gitBranches => 'Branches';

  @override
  String gitChanges(int n) {
    return 'Changes ($n)';
  }

  @override
  String get gitClean => 'No changes, working tree is clean';

  @override
  String get gitCommitAll => 'Commit all changes';

  @override
  String get gitCommitMessage => 'Commit message';

  @override
  String gitCommitStaged(int n) {
    return 'Commit $n staged';
  }

  @override
  String get gitCommitted => 'Committed';

  @override
  String get gitDetached => '(detached HEAD)';

  @override
  String get gitDiffTruncated =>
      'Diff is too long; only the first 512 KB is shown.';

  @override
  String get gitDiscard => 'Discard changes';

  @override
  String gitDiscardConfirm(String file) {
    return 'Discard all changes in $file? This can\'t be undone.';
  }

  @override
  String get gitFetch => 'Fetch';

  @override
  String get gitHistory => 'History';

  @override
  String get gitMessageRequired => 'Write a commit message';

  @override
  String get gitNewBranch => 'New branch';

  @override
  String get gitNoCommits => 'No commits yet';

  @override
  String get gitNoDiff => 'No differences';

  @override
  String get gitNothingToCommit => 'Nothing to commit';

  @override
  String get gitNotRepo => 'This folder is not a Git repository';

  @override
  String get gitPull => 'Pull';

  @override
  String get gitPullFailed => 'Couldn\'t fetch from the remote';

  @override
  String get gitPush => 'Push';

  @override
  String get gitPushFailed => 'Push failed';

  @override
  String get gitRemoteBranches => 'Remote branches';

  @override
  String get gitStage => 'Stage';

  @override
  String get gitStageAll => 'Stage all';

  @override
  String get gitStaged => 'Staged';

  @override
  String gitSwitched(String branch) {
    return 'Switched to $branch';
  }

  @override
  String get gitUnstage => 'Unstage';

  @override
  String get gitUnstaged => 'Not staged';

  @override
  String get maintenanceActive => 'In maintenance';

  @override
  String get maintenanceAdd => 'New maintenance window';

  @override
  String maintenanceDeleteConfirm(String name) {
    return 'Delete maintenance window \"$name\"?';
  }

  @override
  String get maintenanceDuration => 'Duration (starts now)';

  @override
  String get maintenanceEmpty => 'No maintenance windows';

  @override
  String get maintenanceEnded => 'Ended';

  @override
  String get maintenanceExplain =>
      'During a maintenance window, downtime of the selected sites is not alerted.';

  @override
  String get maintenanceInactive => 'Inactive';

  @override
  String get maintenanceName => 'Name';

  @override
  String get maintenanceNeedsSites => 'Enter a name and pick at least one site';

  @override
  String get maintenanceScheduled => 'Scheduled';

  @override
  String get maintenanceTitle => 'Maintenance windows';

  @override
  String get portsExplain =>
      'Ports listening only on localhost can be shared to your tailnet (not the internet) and opened on the phone.';

  @override
  String portsLocalOnly(String address) {
    return 'Local only ($address)';
  }

  @override
  String portsOpen(String address) {
    return 'Reachable over tailnet ($address)';
  }

  @override
  String get portsShare => 'Share';

  @override
  String portsShareConfirm(int port) {
    return 'Share port $port to your tailnet over HTTPS?';
  }

  @override
  String get portsShared => 'Shared to tailnet (HTTPS)';

  @override
  String get portsUnshare => 'Stop sharing';

  @override
  String get processesByCpu => 'CPU';

  @override
  String get processesByMemory => 'Memory';

  @override
  String processesConfirm(String action, String name, int pid) {
    return '$action: $name ($pid)?';
  }

  @override
  String get processesKill => 'Force kill';

  @override
  String get processesTerminate => 'Terminate';

  @override
  String get quickActionNoOutput => '(no output)';

  @override
  String get quickActionRun => 'Run';

  @override
  String quickActionRunConfirm(String name, String host) {
    return 'Run \"$name\" on $host?';
  }

  @override
  String get quickActionRunning => 'Running…';

  @override
  String get quickActionsTitle => 'Quick actions';

  @override
  String get siteAddToHomepage => 'Also add to Homepage';

  @override
  String get siteCertExpiry => 'SSL expiry warning';

  @override
  String get siteCertExpiryHint => 'Notify before the certificate expires';

  @override
  String get siteHomepageFailed =>
      'Site added, but Homepage couldn\'t be updated';

  @override
  String get siteHomepageGroup => 'Homepage group';

  @override
  String get toolsAudit => 'Activity log';

  @override
  String get toolsClipboard => 'Clipboard';

  @override
  String get toolsPorts => 'Ports';

  @override
  String get toolsPortsHint => 'Open dev servers on the phone';

  @override
  String get toolsProcesses => 'Processes';

  @override
  String get toolsScreenshot => 'Screenshot';

  @override
  String get toolsScreenshotRetake => 'Take again';

  @override
  String get toolsTitle => 'Tools';

  @override
  String get voiceEmpty => 'No speech recognized';

  @override
  String get voiceNoPermission => 'Microphone permission is required';

  @override
  String get voiceRecord => 'Voice message';

  @override
  String voiceRecording(String time) {
    return 'Recording $time';
  }

  @override
  String get voiceStop => 'Stop and transcribe';

  @override
  String get voiceTranscribing => 'Transcribing…';

  @override
  String notifDiskFullTitle(String host) {
    return '$host: disk almost full';
  }

  @override
  String notifDiskFullBody(String mount, int percent) {
    return '$mount is $percent% full';
  }

  @override
  String notifDiskOkTitle(String host) {
    return '$host: disk space OK again';
  }

  @override
  String notifServiceFailedTitle(String host) {
    return '$host: service failed';
  }

  @override
  String notifServiceRecoveredTitle(String host) {
    return '$host: service recovered';
  }

  @override
  String notifGrafanaAlertTitle(String name) {
    return 'Alert: $name';
  }

  @override
  String notifGrafanaResolvedTitle(String name) {
    return 'Resolved: $name';
  }

  @override
  String notifCommandDoneTitle(String host) {
    return '$host: command finished';
  }

  @override
  String notifCommandFailedTitle(String host, int code) {
    return '$host: command failed (exit $code)';
  }

  @override
  String notifCommandBody(String command, int seconds) {
    return '$command · $seconds s';
  }

  @override
  String get agentAlerts => 'Alerts (disk, services, Grafana)';

  @override
  String get agentAlertsDiskPercent => 'Disk full threshold (%)';

  @override
  String get agentAlertsInterval => 'Check every (seconds)';

  @override
  String get agentAlertsFailedServices => 'Notify when a systemd service fails';

  @override
  String get agentAlertsGrafana => 'Grafana alerts';

  @override
  String get agentAlertsDatasources => 'Prometheus datasource UIDs';

  @override
  String get agentAlertsDatasourcesHint =>
      'Comma separated; Grafana-managed alerts are always included';

  @override
  String get agentAlertsUseProfileGrafana => 'Use Grafana from my profile';

  @override
  String get agentFeatDesktop => 'Desktop (clipboard, screenshot)';

  @override
  String get agentFeatTranscribe => 'Voice transcription';

  @override
  String get grafanaAlerts => 'Alerts';

  @override
  String get grafanaActiveOnly => 'Active';

  @override
  String get grafanaAllRules => 'All rules';

  @override
  String grafanaAllNormal(int n) {
    return 'All $n rules are normal';
  }

  @override
  String grafanaActiveAlerts(int active, int total) {
    return '$active of $total rules active';
  }

  @override
  String get grafanaAlertsNote =>
      'Phone notifications for these alerts come from the agent (Agent settings › Alerts).';

  @override
  String get dozzleShareLog => 'Share log file';

  @override
  String get shareTitle => 'Send to computer';

  @override
  String shareItems(int n) {
    String _temp0 = intl.Intl.pluralLogic(
      n,
      locale: localeName,
      other: '$n items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String get shareText => 'Text';

  @override
  String get shareToHost => 'Computer';

  @override
  String get shareFolder => 'Folder';

  @override
  String get shareSend => 'Send';

  @override
  String shareSent(int n, String host) {
    return '$n item(s) sent to $host';
  }

  @override
  String get claudeWorktree => 'Separate git worktree';

  @override
  String get claudeWorktreeHint =>
      'New branch in a sibling folder; your working copy stays untouched';

  @override
  String get agentNoDisplay =>
      'No desktop session on the computer (nobody logged in?)';

  @override
  String get agentPortPublic =>
      'This port is already reachable over the tailnet';

  @override
  String get grafanaExplore => 'Quick query';

  @override
  String get grafanaExploreHint => 'PromQL / LogQL, like Explore';

  @override
  String get grafanaExploreEmpty => 'Write a query and run it';

  @override
  String get grafanaNoDatasources => 'No Prometheus or Loki datasource';

  @override
  String get grafanaRun => 'Run';

  @override
  String filesShowAll(int count) {
    return 'Show $count more';
  }

  @override
  String get ntfyExplain =>
      'Notifications arrive in the ntfy app on this phone; sign in to the server there (Settings › Manage users). The topics below become \"Open in ntfy\" shortcuts.';

  @override
  String get scriberrExplain =>
      'Voice messages are transcribed on the PC through the Tiphys agent, which holds the Scriberr key. Choose the language and model here.';

  @override
  String get commonRefresh => 'Refresh';

  @override
  String get claudeInTerminalNote =>
      'This session is open in a terminal on the PC. Read it here or take it over on the phone.';

  @override
  String get claudeTerminalSessions => 'Open in terminal';

  @override
  String get claudeTerminalSessionsHint =>
      'Claude Code sessions running on the PC outside Tiphys. Read-only here.';

  @override
  String get claudePromptOptional => 'First message (optional)';

  @override
  String get claudeUntitled => 'New session';

  @override
  String get claudeTakeover => 'Take over on phone';

  @override
  String claudeTakeoverConfirm(String id) {
    return 'Claude in the PC terminal will be closed and this session continues here with its full history. To go back to the terminal later run:\nclaude --resume $id';
  }

  @override
  String get claudeTerminalBusy =>
      'Claude is working in the terminal right now. Try again when it finishes.';

  @override
  String get claudeTerminalGone =>
      'This session is no longer open in the terminal.';

  @override
  String get claudeTerminalStuck =>
      'The terminal session did not close. Close it on the PC and try again.';

  @override
  String voiceTranscribingProgress(int secs, int estimate) {
    return 'Transcribing on the server · $secs s / ~$estimate s';
  }

  @override
  String get claudeRestored => 'Agent restarted · continue where you left off';

  @override
  String get claudeCompacted => 'Earlier part was summarized';

  @override
  String get claudeSessionGone =>
      'This session no longer exists. Open it from History to continue.';

  @override
  String get claudeReconnecting => 'Connection lost, reconnecting…';

  @override
  String get claudeOutboxWaiting => 'waiting for connection';

  @override
  String get claudeOutboxSending => 'sending…';

  @override
  String get claudeDecisionFailedTitle => 'Could not send your decision';

  @override
  String get claudeDecisionFailedBody =>
      'Open Tiphys to answer the permission request.';

  @override
  String get agentSection => 'Agent';

  @override
  String get agentVersion => 'Version';

  @override
  String agentOutdated(String version) {
    return '$version · outdated';
  }

  @override
  String agentOutdatedHint(String version) {
    return 'This app expects agent $version. Update it on the PC with tools/deploy-agent.sh (remote) or by rebuilding the agent (local).';
  }

  @override
  String get agentUptime => 'Running for';

  @override
  String agentUptimeDays(int days, int hours) {
    return '$days d $hours h';
  }

  @override
  String agentUptimeHours(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String agentUptimeMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get agentMemory => 'Memory';

  @override
  String agentMemoryValue(String agent, String children) {
    return 'agent $agent · Claude/commands $children';
  }

  @override
  String get agentRestarts => 'Unexpected restarts';

  @override
  String notifAgentRestartedTitle(String host) {
    return '$host: agent restarted unexpectedly';
  }

  @override
  String get notifAgentRestartedBody =>
      'It crashed or ran out of memory. Live Claude sessions were restored.';

  @override
  String get agentRestartsWindow => 'last 24 hours';
}
