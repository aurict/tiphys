import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_tr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('tr'),
  ];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Tiphys'**
  String get appName;

  /// No description provided for @tabHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get tabHome;

  /// No description provided for @tabClaude.
  ///
  /// In en, this message translates to:
  /// **'Claude'**
  String get tabClaude;

  /// No description provided for @tabTerminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get tabTerminal;

  /// No description provided for @tabFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get tabFiles;

  /// No description provided for @tabSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get tabSystem;

  /// No description provided for @homeInfra.
  ///
  /// In en, this message translates to:
  /// **'Infrastructure'**
  String get homeInfra;

  /// No description provided for @homeOnlineCount.
  ///
  /// In en, this message translates to:
  /// **'{online}/{total} online'**
  String homeOnlineCount(int online, int total);

  /// No description provided for @homeNoHosts.
  ///
  /// In en, this message translates to:
  /// **'No hosts yet'**
  String get homeNoHosts;

  /// No description provided for @homeAddHost.
  ///
  /// In en, this message translates to:
  /// **'Add a host in Settings'**
  String get homeAddHost;

  /// No description provided for @homeClaudeSessions.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{no sessions} =1{session} other{sessions}}'**
  String homeClaudeSessions(int count);

  /// No description provided for @homeClaudeWaiting.
  ///
  /// In en, this message translates to:
  /// **'{count} waiting'**
  String homeClaudeWaiting(int count);

  /// No description provided for @homeNewClaudeSession.
  ///
  /// In en, this message translates to:
  /// **'New Claude session'**
  String get homeNewClaudeSession;

  /// No description provided for @homeCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU {percent}'**
  String homeCpu(String percent);

  /// No description provided for @homeRam.
  ///
  /// In en, this message translates to:
  /// **'RAM {percent}'**
  String homeRam(String percent);

  /// No description provided for @homeQuickAccess.
  ///
  /// In en, this message translates to:
  /// **'Quick access'**
  String get homeQuickAccess;

  /// No description provided for @homeOpenInBrowser.
  ///
  /// In en, this message translates to:
  /// **'in browser'**
  String get homeOpenInBrowser;

  /// No description provided for @homeTabsCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 tab} other{{count} tabs}}'**
  String homeTabsCount(int count);

  /// No description provided for @homeLive.
  ///
  /// In en, this message translates to:
  /// **'live'**
  String get homeLive;

  /// No description provided for @homeLastHour.
  ///
  /// In en, this message translates to:
  /// **'CPU · 1 h'**
  String get homeLastHour;

  /// No description provided for @homeNotConnected.
  ///
  /// In en, this message translates to:
  /// **'not connected'**
  String get homeNotConnected;

  /// No description provided for @homeSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get homeSearch;

  /// No description provided for @commonLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get commonLoading;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get commonRetry;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @commonAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// No description provided for @commonEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get commonEdit;

  /// No description provided for @commonDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get commonDone;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @commonCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get commonCopy;

  /// No description provided for @commonCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get commonCopied;

  /// No description provided for @commonShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get commonShare;

  /// No description provided for @commonConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get commonConfirm;

  /// No description provided for @commonContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get commonContinue;

  /// No description provided for @commonTest.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get commonTest;

  /// No description provided for @commonTesting.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get commonTesting;

  /// No description provided for @commonTestOk.
  ///
  /// In en, this message translates to:
  /// **'Connection works'**
  String get commonTestOk;

  /// No description provided for @commonTestFailed.
  ///
  /// In en, this message translates to:
  /// **'Connection failed: {reason}'**
  String commonTestFailed(String reason);

  /// No description provided for @commonOptional.
  ///
  /// In en, this message translates to:
  /// **'optional'**
  String get commonOptional;

  /// No description provided for @commonRequired.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get commonRequired;

  /// No description provided for @commonNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get commonNone;

  /// No description provided for @commonEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get commonEmpty;

  /// No description provided for @commonError.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get commonError;

  /// No description provided for @commonUnsaved.
  ///
  /// In en, this message translates to:
  /// **'You have unsaved changes'**
  String get commonUnsaved;

  /// No description provided for @commonDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get commonDiscard;

  /// No description provided for @commonOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get commonOn;

  /// No description provided for @commonOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get commonOff;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsHosts.
  ///
  /// In en, this message translates to:
  /// **'Hosts'**
  String get settingsHosts;

  /// No description provided for @settingsHostsHint.
  ///
  /// In en, this message translates to:
  /// **'Servers and the PC: address, SSH, agent, wake'**
  String get settingsHostsHint;

  /// No description provided for @settingsKeys.
  ///
  /// In en, this message translates to:
  /// **'Keys & secrets'**
  String get settingsKeys;

  /// No description provided for @settingsKeysHint.
  ///
  /// In en, this message translates to:
  /// **'SSH keys, API tokens, passwords'**
  String get settingsKeysHint;

  /// No description provided for @settingsClaude.
  ///
  /// In en, this message translates to:
  /// **'Claude'**
  String get settingsClaude;

  /// No description provided for @settingsClaudeHint.
  ///
  /// In en, this message translates to:
  /// **'Agent, defaults, profiles, favourite folders'**
  String get settingsClaudeHint;

  /// No description provided for @settingsIntegrations.
  ///
  /// In en, this message translates to:
  /// **'Integrations'**
  String get settingsIntegrations;

  /// No description provided for @settingsIntegrationsHint.
  ///
  /// In en, this message translates to:
  /// **'Grafana, Dozzle, Homepage, Uptime Kuma, ntfy, Scriberr'**
  String get settingsIntegrationsHint;

  /// No description provided for @settingsTerminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get settingsTerminal;

  /// No description provided for @settingsTerminalHint.
  ///
  /// In en, this message translates to:
  /// **'Font, keys bar, snippets'**
  String get settingsTerminalHint;

  /// No description provided for @settingsFiles.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get settingsFiles;

  /// No description provided for @settingsFilesHint.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks, hidden files'**
  String get settingsFilesHint;

  /// No description provided for @settingsQuickActions.
  ///
  /// In en, this message translates to:
  /// **'Quick actions'**
  String get settingsQuickActions;

  /// No description provided for @settingsQuickActionsHint.
  ///
  /// In en, this message translates to:
  /// **'Your own one-tap commands'**
  String get settingsQuickActionsHint;

  /// No description provided for @settingsHome.
  ///
  /// In en, this message translates to:
  /// **'Home screen'**
  String get settingsHome;

  /// No description provided for @settingsHomeHint.
  ///
  /// In en, this message translates to:
  /// **'Cards and their order'**
  String get settingsHomeHint;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsAppearanceHint.
  ///
  /// In en, this message translates to:
  /// **'Theme and language'**
  String get settingsAppearanceHint;

  /// No description provided for @settingsSecurity.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get settingsSecurity;

  /// No description provided for @settingsSecurityHint.
  ///
  /// In en, this message translates to:
  /// **'Biometrics, PIN, auto-lock'**
  String get settingsSecurityHint;

  /// No description provided for @settingsProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile file'**
  String get settingsProfile;

  /// No description provided for @settingsProfileHint.
  ///
  /// In en, this message translates to:
  /// **'Import, export, reset'**
  String get settingsProfileHint;

  /// No description provided for @settingsNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotifications;

  /// No description provided for @settingsNotificationsHint.
  ///
  /// In en, this message translates to:
  /// **'What to be told about'**
  String get settingsNotificationsHint;

  /// No description provided for @appearanceTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get appearanceTheme;

  /// No description provided for @appearanceThemeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get appearanceThemeSystem;

  /// No description provided for @appearanceThemeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceThemeLight;

  /// No description provided for @appearanceThemeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceThemeDark;

  /// No description provided for @appearanceLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get appearanceLanguage;

  /// No description provided for @appearanceLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'System language'**
  String get appearanceLanguageSystem;

  /// No description provided for @appearanceLanguageTr.
  ///
  /// In en, this message translates to:
  /// **'Türkçe'**
  String get appearanceLanguageTr;

  /// No description provided for @appearanceLanguageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get appearanceLanguageEn;

  /// No description provided for @hostsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No hosts. Add your PC and servers.'**
  String get hostsEmpty;

  /// No description provided for @hostAdd.
  ///
  /// In en, this message translates to:
  /// **'Add host'**
  String get hostAdd;

  /// No description provided for @hostEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit host'**
  String get hostEdit;

  /// No description provided for @hostId.
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get hostId;

  /// No description provided for @hostIdHint.
  ///
  /// In en, this message translates to:
  /// **'lowercase, e.g. atlas'**
  String get hostIdHint;

  /// No description provided for @hostName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get hostName;

  /// No description provided for @hostColor.
  ///
  /// In en, this message translates to:
  /// **'Colour'**
  String get hostColor;

  /// No description provided for @hostAddress.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get hostAddress;

  /// No description provided for @hostAddressHint.
  ///
  /// In en, this message translates to:
  /// **'Tailscale name or IP'**
  String get hostAddressHint;

  /// No description provided for @hostSsh.
  ///
  /// In en, this message translates to:
  /// **'SSH'**
  String get hostSsh;

  /// No description provided for @hostSshPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get hostSshPort;

  /// No description provided for @hostSshUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get hostSshUser;

  /// No description provided for @hostSshAuth.
  ///
  /// In en, this message translates to:
  /// **'Sign-in'**
  String get hostSshAuth;

  /// No description provided for @hostSshAuthKey.
  ///
  /// In en, this message translates to:
  /// **'SSH key'**
  String get hostSshAuthKey;

  /// No description provided for @hostSshAuthPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get hostSshAuthPassword;

  /// No description provided for @hostSshKey.
  ///
  /// In en, this message translates to:
  /// **'Key'**
  String get hostSshKey;

  /// No description provided for @hostSshPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get hostSshPassword;

  /// No description provided for @hostTmux.
  ///
  /// In en, this message translates to:
  /// **'tmux session'**
  String get hostTmux;

  /// No description provided for @hostAgent.
  ///
  /// In en, this message translates to:
  /// **'Tiphys agent'**
  String get hostAgent;

  /// No description provided for @hostAgentUrl.
  ///
  /// In en, this message translates to:
  /// **'Agent address'**
  String get hostAgentUrl;

  /// No description provided for @hostAgentToken.
  ///
  /// In en, this message translates to:
  /// **'Agent token'**
  String get hostAgentToken;

  /// No description provided for @hostAgentNone.
  ///
  /// In en, this message translates to:
  /// **'No agent on this host'**
  String get hostAgentNone;

  /// No description provided for @hostWake.
  ///
  /// In en, this message translates to:
  /// **'Wake-on-LAN'**
  String get hostWake;

  /// No description provided for @hostWakeMac.
  ///
  /// In en, this message translates to:
  /// **'MAC address'**
  String get hostWakeMac;

  /// No description provided for @hostWakeVia.
  ///
  /// In en, this message translates to:
  /// **'Send from'**
  String get hostWakeVia;

  /// No description provided for @hostTags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get hostTags;

  /// No description provided for @hostDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}? Things that use this host will lose it.'**
  String hostDeleteConfirm(String name);

  /// No description provided for @keysEmpty.
  ///
  /// In en, this message translates to:
  /// **'No keys or secrets yet.'**
  String get keysEmpty;

  /// No description provided for @keysSshKeys.
  ///
  /// In en, this message translates to:
  /// **'SSH keys'**
  String get keysSshKeys;

  /// No description provided for @keysTokens.
  ///
  /// In en, this message translates to:
  /// **'Tokens and passwords'**
  String get keysTokens;

  /// No description provided for @keyImportFile.
  ///
  /// In en, this message translates to:
  /// **'Import from file'**
  String get keyImportFile;

  /// No description provided for @keyPaste.
  ///
  /// In en, this message translates to:
  /// **'Paste a key'**
  String get keyPaste;

  /// No description provided for @keyGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate on this phone'**
  String get keyGenerate;

  /// No description provided for @keyLabel.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get keyLabel;

  /// No description provided for @keyPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get keyPrivate;

  /// No description provided for @keyPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Passphrase'**
  String get keyPassphrase;

  /// No description provided for @keyPublic.
  ///
  /// In en, this message translates to:
  /// **'Public key'**
  String get keyPublic;

  /// No description provided for @keyCopyPublic.
  ///
  /// In en, this message translates to:
  /// **'Copy public key'**
  String get keyCopyPublic;

  /// No description provided for @keyInstallOnHost.
  ///
  /// In en, this message translates to:
  /// **'Add to a host\'s authorized_keys'**
  String get keyInstallOnHost;

  /// No description provided for @keyInvalid.
  ///
  /// In en, this message translates to:
  /// **'This doesn\'t look like an SSH private key'**
  String get keyInvalid;

  /// No description provided for @keyGenerated.
  ///
  /// In en, this message translates to:
  /// **'Key generated'**
  String get keyGenerated;

  /// No description provided for @secretAdd.
  ///
  /// In en, this message translates to:
  /// **'Add secret'**
  String get secretAdd;

  /// No description provided for @secretValue.
  ///
  /// In en, this message translates to:
  /// **'Value'**
  String get secretValue;

  /// No description provided for @secretStoredSafely.
  ///
  /// In en, this message translates to:
  /// **'Stored in the Android Keystore. Never written to the profile file in plain text.'**
  String get secretStoredSafely;

  /// No description provided for @secretMissing.
  ///
  /// In en, this message translates to:
  /// **'Missing secret: {id}'**
  String secretMissing(String id);

  /// No description provided for @profileExport.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get profileExport;

  /// No description provided for @profileExportPlain.
  ///
  /// In en, this message translates to:
  /// **'Without secrets'**
  String get profileExportPlain;

  /// No description provided for @profileExportPlainHint.
  ///
  /// In en, this message translates to:
  /// **'Safe to share. Keys and tokens are left out.'**
  String get profileExportPlainHint;

  /// No description provided for @profileExportEncrypted.
  ///
  /// In en, this message translates to:
  /// **'Encrypted backup'**
  String get profileExportEncrypted;

  /// No description provided for @profileExportEncryptedHint.
  ///
  /// In en, this message translates to:
  /// **'Keys and tokens included, encrypted with a passphrase.'**
  String get profileExportEncryptedHint;

  /// No description provided for @profileImport.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get profileImport;

  /// No description provided for @profileImportHint.
  ///
  /// In en, this message translates to:
  /// **'Choose a .tiphys.json file'**
  String get profileImportHint;

  /// No description provided for @profileReset.
  ///
  /// In en, this message translates to:
  /// **'Reset everything'**
  String get profileReset;

  /// No description provided for @profileResetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete all settings and secrets on this phone?'**
  String get profileResetConfirm;

  /// No description provided for @profilePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Passphrase'**
  String get profilePassphrase;

  /// No description provided for @profilePassphraseRepeat.
  ///
  /// In en, this message translates to:
  /// **'Repeat passphrase'**
  String get profilePassphraseRepeat;

  /// No description provided for @profilePassphraseMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passphrases don\'t match'**
  String get profilePassphraseMismatch;

  /// No description provided for @profilePassphraseShort.
  ///
  /// In en, this message translates to:
  /// **'At least 10 characters'**
  String get profilePassphraseShort;

  /// No description provided for @profilePassphraseWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong passphrase or damaged file'**
  String get profilePassphraseWrong;

  /// No description provided for @profileExported.
  ///
  /// In en, this message translates to:
  /// **'Profile exported'**
  String get profileExported;

  /// No description provided for @profileImported.
  ///
  /// In en, this message translates to:
  /// **'Profile imported'**
  String get profileImported;

  /// No description provided for @profilePreviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Review changes'**
  String get profilePreviewTitle;

  /// No description provided for @profilePreviewAdded.
  ///
  /// In en, this message translates to:
  /// **'Will be added'**
  String get profilePreviewAdded;

  /// No description provided for @profilePreviewChanged.
  ///
  /// In en, this message translates to:
  /// **'Will change'**
  String get profilePreviewChanged;

  /// No description provided for @profilePreviewRemoved.
  ///
  /// In en, this message translates to:
  /// **'Will be removed'**
  String get profilePreviewRemoved;

  /// No description provided for @profilePreviewUnchanged.
  ///
  /// In en, this message translates to:
  /// **'No changes'**
  String get profilePreviewUnchanged;

  /// No description provided for @profileModeMerge.
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get profileModeMerge;

  /// No description provided for @profileModeMergeHint.
  ///
  /// In en, this message translates to:
  /// **'Same IDs are overwritten, new ones are added, nothing is removed.'**
  String get profileModeMergeHint;

  /// No description provided for @profileModeReplace.
  ///
  /// In en, this message translates to:
  /// **'Replace all'**
  String get profileModeReplace;

  /// No description provided for @profileModeReplaceHint.
  ///
  /// In en, this message translates to:
  /// **'Everything becomes exactly what is in the file.'**
  String get profileModeReplaceHint;

  /// No description provided for @profileMissingSecrets.
  ///
  /// In en, this message translates to:
  /// **'Secrets you need to enter again'**
  String get profileMissingSecrets;

  /// No description provided for @profileErrorFormat.
  ///
  /// In en, this message translates to:
  /// **'This is not a Tiphys profile'**
  String get profileErrorFormat;

  /// No description provided for @profileErrorNewer.
  ///
  /// In en, this message translates to:
  /// **'This file was made by a newer Tiphys (schema {version})'**
  String profileErrorNewer(int version);

  /// No description provided for @profileErrorInvalid.
  ///
  /// In en, this message translates to:
  /// **'The file has errors: {details}'**
  String profileErrorInvalid(String details);

  /// No description provided for @profileErrorJson.
  ///
  /// In en, this message translates to:
  /// **'The file is not valid JSON'**
  String get profileErrorJson;

  /// No description provided for @securityBiometric.
  ///
  /// In en, this message translates to:
  /// **'Unlock with fingerprint'**
  String get securityBiometric;

  /// No description provided for @securityPin.
  ///
  /// In en, this message translates to:
  /// **'PIN'**
  String get securityPin;

  /// No description provided for @securityPinSet.
  ///
  /// In en, this message translates to:
  /// **'Set PIN'**
  String get securityPinSet;

  /// No description provided for @securityPinChange.
  ///
  /// In en, this message translates to:
  /// **'Change PIN'**
  String get securityPinChange;

  /// No description provided for @securityPinEnter.
  ///
  /// In en, this message translates to:
  /// **'Enter PIN'**
  String get securityPinEnter;

  /// No description provided for @securityPinNew.
  ///
  /// In en, this message translates to:
  /// **'New PIN'**
  String get securityPinNew;

  /// No description provided for @securityPinRepeat.
  ///
  /// In en, this message translates to:
  /// **'Repeat PIN'**
  String get securityPinRepeat;

  /// No description provided for @securityPinWrong.
  ///
  /// In en, this message translates to:
  /// **'Wrong PIN'**
  String get securityPinWrong;

  /// No description provided for @securityPinShort.
  ///
  /// In en, this message translates to:
  /// **'At least 6 digits'**
  String get securityPinShort;

  /// No description provided for @securityAutoLock.
  ///
  /// In en, this message translates to:
  /// **'Auto-lock'**
  String get securityAutoLock;

  /// No description provided for @securityAutoLockSeconds.
  ///
  /// In en, this message translates to:
  /// **'{seconds, plural, =0{Immediately} other{After {seconds} s}}'**
  String securityAutoLockSeconds(int seconds);

  /// No description provided for @lockTitle.
  ///
  /// In en, this message translates to:
  /// **'Tiphys is locked'**
  String get lockTitle;

  /// No description provided for @lockUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get lockUnlock;

  /// No description provided for @lockBiometricReason.
  ///
  /// In en, this message translates to:
  /// **'Unlock Tiphys'**
  String get lockBiometricReason;

  /// No description provided for @homeCardsInfra.
  ///
  /// In en, this message translates to:
  /// **'Infrastructure'**
  String get homeCardsInfra;

  /// No description provided for @homeCardsClaude.
  ///
  /// In en, this message translates to:
  /// **'Claude'**
  String get homeCardsClaude;

  /// No description provided for @homeCardsSystem.
  ///
  /// In en, this message translates to:
  /// **'PC status'**
  String get homeCardsSystem;

  /// No description provided for @homeCardsGrafana.
  ///
  /// In en, this message translates to:
  /// **'Grafana'**
  String get homeCardsGrafana;

  /// No description provided for @homeCardsDozzle.
  ///
  /// In en, this message translates to:
  /// **'Dozzle'**
  String get homeCardsDozzle;

  /// No description provided for @homeCardsQuickAccess.
  ///
  /// In en, this message translates to:
  /// **'Quick access'**
  String get homeCardsQuickAccess;

  /// No description provided for @comingInPhase.
  ///
  /// In en, this message translates to:
  /// **'Coming in phase {phase}'**
  String comingInPhase(int phase);

  /// No description provided for @relativeNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get relativeNow;

  /// No description provided for @relativeMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String relativeMinutes(int count);

  /// No description provided for @relativeHours.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String relativeHours(int count);

  /// No description provided for @relativeDays.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{yesterday} other{{count} days ago}}'**
  String relativeDays(int count);

  /// No description provided for @claudeAgentHost.
  ///
  /// In en, this message translates to:
  /// **'Agent that runs Claude'**
  String get claudeAgentHost;

  /// No description provided for @claudeModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get claudeModel;

  /// No description provided for @claudeEffort.
  ///
  /// In en, this message translates to:
  /// **'Thinking effort'**
  String get claudeEffort;

  /// No description provided for @claudePermissionMode.
  ///
  /// In en, this message translates to:
  /// **'Permission mode'**
  String get claudePermissionMode;

  /// No description provided for @claudeModeBypass.
  ///
  /// In en, this message translates to:
  /// **'Don\'t ask (bypass permissions)'**
  String get claudeModeBypass;

  /// No description provided for @claudeModeAcceptEdits.
  ///
  /// In en, this message translates to:
  /// **'Accept edits, ask for commands'**
  String get claudeModeAcceptEdits;

  /// No description provided for @claudeModeDefault.
  ///
  /// In en, this message translates to:
  /// **'Ask every time'**
  String get claudeModeDefault;

  /// No description provided for @claudeModePlan.
  ///
  /// In en, this message translates to:
  /// **'Plan first'**
  String get claudeModePlan;

  /// No description provided for @claudeProfiles.
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get claudeProfiles;

  /// No description provided for @claudeProfilesHint.
  ///
  /// In en, this message translates to:
  /// **'One per line: id = config folder'**
  String get claudeProfilesHint;

  /// No description provided for @claudeFavoriteFolders.
  ///
  /// In en, this message translates to:
  /// **'Favourite folders'**
  String get claudeFavoriteFolders;

  /// No description provided for @claudePinnedCommands.
  ///
  /// In en, this message translates to:
  /// **'Pinned slash commands'**
  String get claudePinnedCommands;

  /// No description provided for @durationSeconds.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String durationSeconds(int seconds);

  /// No description provided for @filesBookmarks.
  ///
  /// In en, this message translates to:
  /// **'Bookmarks'**
  String get filesBookmarks;

  /// No description provided for @filesBookmarksHint.
  ///
  /// In en, this message translates to:
  /// **'One per line: host:path'**
  String get filesBookmarksHint;

  /// No description provided for @filesShowHidden.
  ///
  /// In en, this message translates to:
  /// **'Show hidden files'**
  String get filesShowHidden;

  /// No description provided for @hostWakeViaHint.
  ///
  /// In en, this message translates to:
  /// **'The wake packet must be sent from the PC\'s own local network. \"This phone\" works only while the phone is on that Wi-Fi.'**
  String get hostWakeViaHint;

  /// No description provided for @hostWakeViaPhone.
  ///
  /// In en, this message translates to:
  /// **'This phone (same Wi-Fi)'**
  String get hostWakeViaPhone;

  /// No description provided for @integrationAdd.
  ///
  /// In en, this message translates to:
  /// **'Add {name}'**
  String integrationAdd(String name);

  /// No description provided for @integrationOthers.
  ///
  /// In en, this message translates to:
  /// **'Others'**
  String get integrationOthers;

  /// No description provided for @integrationNotSet.
  ///
  /// In en, this message translates to:
  /// **'not set up'**
  String get integrationNotSet;

  /// No description provided for @integrationToken.
  ///
  /// In en, this message translates to:
  /// **'Use a token'**
  String get integrationToken;

  /// No description provided for @integrationServiceAccountToken.
  ///
  /// In en, this message translates to:
  /// **'Service account token'**
  String get integrationServiceAccountToken;

  /// No description provided for @integrationAccessToken.
  ///
  /// In en, this message translates to:
  /// **'Access token'**
  String get integrationAccessToken;

  /// No description provided for @integrationApiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get integrationApiKey;

  /// No description provided for @integrationLogin.
  ///
  /// In en, this message translates to:
  /// **'Sign-in required'**
  String get integrationLogin;

  /// No description provided for @integrationDefaults.
  ///
  /// In en, this message translates to:
  /// **'Defaults'**
  String get integrationDefaults;

  /// No description provided for @integrationDefaultDashboard.
  ///
  /// In en, this message translates to:
  /// **'Default dashboard UID'**
  String get integrationDefaultDashboard;

  /// No description provided for @integrationRefreshSeconds.
  ///
  /// In en, this message translates to:
  /// **'Refresh (s)'**
  String get integrationRefreshSeconds;

  /// No description provided for @integrationRange.
  ///
  /// In en, this message translates to:
  /// **'Time range'**
  String get integrationRange;

  /// No description provided for @integrationBrowserUrl.
  ///
  /// In en, this message translates to:
  /// **'Address for the browser'**
  String get integrationBrowserUrl;

  /// No description provided for @integrationReadVia.
  ///
  /// In en, this message translates to:
  /// **'Read through agent on'**
  String get integrationReadVia;

  /// No description provided for @integrationServicesFile.
  ///
  /// In en, this message translates to:
  /// **'services.yaml path'**
  String get integrationServicesFile;

  /// No description provided for @integrationOpenInApp.
  ///
  /// In en, this message translates to:
  /// **'Open services inside the app'**
  String get integrationOpenInApp;

  /// No description provided for @integrationNeedsAgentHost.
  ///
  /// In en, this message translates to:
  /// **'Add a host with a Tiphys agent first'**
  String get integrationNeedsAgentHost;

  /// No description provided for @integrationDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove this integration?'**
  String get integrationDeleteConfirm;

  /// No description provided for @notifyClaudeDone.
  ///
  /// In en, this message translates to:
  /// **'When a session finishes'**
  String get notifyClaudeDone;

  /// No description provided for @notifyClaudeWaiting.
  ///
  /// In en, this message translates to:
  /// **'When it needs my approval'**
  String get notifyClaudeWaiting;

  /// No description provided for @notifyClaudeError.
  ///
  /// In en, this message translates to:
  /// **'When it fails'**
  String get notifyClaudeError;

  /// No description provided for @notifySiteDown.
  ///
  /// In en, this message translates to:
  /// **'Site outages'**
  String get notifySiteDown;

  /// No description provided for @notifyPcOffline.
  ///
  /// In en, this message translates to:
  /// **'PC goes offline'**
  String get notifyPcOffline;

  /// No description provided for @notifyServiceDown.
  ///
  /// In en, this message translates to:
  /// **'A service crashes'**
  String get notifyServiceDown;

  /// No description provided for @notifyGrafana.
  ///
  /// In en, this message translates to:
  /// **'Grafana alerts'**
  String get notifyGrafana;

  /// No description provided for @notifyDiskFull.
  ///
  /// In en, this message translates to:
  /// **'Disk almost full warning at'**
  String get notifyDiskFull;

  /// No description provided for @notifyLongCommand.
  ///
  /// In en, this message translates to:
  /// **'Tell me when a long command finishes'**
  String get notifyLongCommand;

  /// No description provided for @ntfyTopics.
  ///
  /// In en, this message translates to:
  /// **'Topics to follow'**
  String get ntfyTopics;

  /// No description provided for @ntfyTopicsHint.
  ///
  /// In en, this message translates to:
  /// **'Comma separated. e.g. siteler for Uptime Kuma alerts'**
  String get ntfyTopicsHint;

  /// No description provided for @quickActionCommand.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get quickActionCommand;

  /// No description provided for @quickActionConfirm.
  ///
  /// In en, this message translates to:
  /// **'Ask before running'**
  String get quickActionConfirm;

  /// No description provided for @scriberrAutoDetect.
  ///
  /// In en, this message translates to:
  /// **'Detect automatically'**
  String get scriberrAutoDetect;

  /// No description provided for @scriberrModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get scriberrModel;

  /// No description provided for @scriberrModelSmall.
  ///
  /// In en, this message translates to:
  /// **'small (fast)'**
  String get scriberrModelSmall;

  /// No description provided for @scriberrModelLarge.
  ///
  /// In en, this message translates to:
  /// **'large-v3 (accurate)'**
  String get scriberrModelLarge;

  /// No description provided for @secretNeedsValue.
  ///
  /// In en, this message translates to:
  /// **'missing'**
  String get secretNeedsValue;

  /// No description provided for @secretUnused.
  ///
  /// In en, this message translates to:
  /// **'not used by any setting'**
  String get secretUnused;

  /// No description provided for @terminalFontSize.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get terminalFontSize;

  /// No description provided for @terminalExtraKeys.
  ///
  /// In en, this message translates to:
  /// **'Extra keys bar'**
  String get terminalExtraKeys;

  /// No description provided for @terminalExtraKeysHint.
  ///
  /// In en, this message translates to:
  /// **'Space separated: esc tab ctrl alt up down left right | ~ /'**
  String get terminalExtraKeysHint;

  /// No description provided for @terminalSnippets.
  ///
  /// In en, this message translates to:
  /// **'Snippets'**
  String get terminalSnippets;

  /// No description provided for @terminalSnippetsHint.
  ///
  /// In en, this message translates to:
  /// **'One per line: name | command | host (optional)'**
  String get terminalSnippetsHint;

  /// No description provided for @terminalThemeNote.
  ///
  /// In en, this message translates to:
  /// **'Terminal colours follow the app theme.'**
  String get terminalThemeNote;

  /// No description provided for @uptimeInterval.
  ///
  /// In en, this message translates to:
  /// **'Check interval (s)'**
  String get uptimeInterval;

  /// No description provided for @uptimeAlertAfter.
  ///
  /// In en, this message translates to:
  /// **'Alert after down for (s)'**
  String get uptimeAlertAfter;

  /// No description provided for @uptimeCertDays.
  ///
  /// In en, this message translates to:
  /// **'Warn days before SSL expiry'**
  String get uptimeCertDays;

  /// No description provided for @uptimeCredentialsOnAgent.
  ///
  /// In en, this message translates to:
  /// **'The Uptime Kuma login stays on the agent; the phone never stores it.'**
  String get uptimeCredentialsOnAgent;

  /// No description provided for @uptimeNotifyRecovery.
  ///
  /// In en, this message translates to:
  /// **'Tell me when a site is back'**
  String get uptimeNotifyRecovery;

  /// No description provided for @sshNoSsh.
  ///
  /// In en, this message translates to:
  /// **'SSH is not set up for this host'**
  String get sshNoSsh;

  /// No description provided for @sshUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Host unreachable (is Tailscale on?)'**
  String get sshUnreachable;

  /// No description provided for @sshAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign-in rejected: check the key or password'**
  String get sshAuthFailed;

  /// No description provided for @sshTimeout.
  ///
  /// In en, this message translates to:
  /// **'Connection timed out'**
  String get sshTimeout;

  /// No description provided for @sshHostKeyChanged.
  ///
  /// In en, this message translates to:
  /// **'The server key changed! Connection stopped for safety.'**
  String get sshHostKeyChanged;

  /// No description provided for @sshConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to {name}…'**
  String sshConnecting(String name);

  /// No description provided for @sshDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected. The tmux session keeps running on the server.'**
  String get sshDisconnected;

  /// No description provided for @sshReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get sshReconnect;

  /// No description provided for @terminalOpenOn.
  ///
  /// In en, this message translates to:
  /// **'New terminal on {name}'**
  String terminalOpenOn(String name);

  /// No description provided for @terminalPickHost.
  ///
  /// In en, this message translates to:
  /// **'Pick a host above to open a terminal.'**
  String get terminalPickHost;

  /// No description provided for @terminalNoSshHosts.
  ///
  /// In en, this message translates to:
  /// **'No host with SSH yet. Add one in Settings › Hosts.'**
  String get terminalNoSshHosts;

  /// No description provided for @filesUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload here'**
  String get filesUpload;

  /// No description provided for @filesUploaded.
  ///
  /// In en, this message translates to:
  /// **'Uploaded {name}'**
  String filesUploaded(String name);

  /// No description provided for @filesUp.
  ///
  /// In en, this message translates to:
  /// **'Parent folder'**
  String get filesUp;

  /// No description provided for @filesTerminalHere.
  ///
  /// In en, this message translates to:
  /// **'Terminal here'**
  String get filesTerminalHere;

  /// No description provided for @filesClaudeHere.
  ///
  /// In en, this message translates to:
  /// **'Claude here'**
  String get filesClaudeHere;

  /// No description provided for @filesNewFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get filesNewFolder;

  /// No description provided for @filesPasteHere.
  ///
  /// In en, this message translates to:
  /// **'Paste here'**
  String get filesPasteHere;

  /// No description provided for @filesEmptyFolder.
  ///
  /// In en, this message translates to:
  /// **'This folder is empty'**
  String get filesEmptyFolder;

  /// No description provided for @filesPreview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get filesPreview;

  /// No description provided for @filesDownload.
  ///
  /// In en, this message translates to:
  /// **'Download / share'**
  String get filesDownload;

  /// No description provided for @filesRename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get filesRename;

  /// No description provided for @filesCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get filesCopy;

  /// No description provided for @filesMove.
  ///
  /// In en, this message translates to:
  /// **'Move'**
  String get filesMove;

  /// No description provided for @filesTrash.
  ///
  /// In en, this message translates to:
  /// **'Move to trash'**
  String get filesTrash;

  /// No description provided for @filesTrashConfirm.
  ///
  /// In en, this message translates to:
  /// **'Move {name} to the trash? You can restore it from the desktop trash.'**
  String filesTrashConfirm(String name);

  /// No description provided for @filesTrashed.
  ///
  /// In en, this message translates to:
  /// **'Moved to trash'**
  String get filesTrashed;

  /// No description provided for @filesMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get filesMore;

  /// No description provided for @filesBinary.
  ///
  /// In en, this message translates to:
  /// **'Binary file: use download to open it'**
  String get filesBinary;

  /// No description provided for @keyNeedsPassphrase.
  ///
  /// In en, this message translates to:
  /// **'This key is protected; enter its passphrase'**
  String get keyNeedsPassphrase;

  /// No description provided for @keyInstalled.
  ///
  /// In en, this message translates to:
  /// **'Key added to {name}'**
  String keyInstalled(String name);

  /// No description provided for @keyDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the key {name} from this phone?'**
  String keyDeleteConfirm(String name);

  /// No description provided for @systemMonitoring.
  ///
  /// In en, this message translates to:
  /// **'Monitoring'**
  String get systemMonitoring;

  /// No description provided for @systemSites.
  ///
  /// In en, this message translates to:
  /// **'Sites (Uptime Kuma)'**
  String get systemSites;

  /// No description provided for @systemUptime.
  ///
  /// In en, this message translates to:
  /// **'up {days} d {hours} h'**
  String systemUptime(int days, int hours);

  /// No description provided for @systemDisk.
  ///
  /// In en, this message translates to:
  /// **'Disk'**
  String get systemDisk;

  /// No description provided for @systemPower.
  ///
  /// In en, this message translates to:
  /// **'Power'**
  String get systemPower;

  /// No description provided for @systemWake.
  ///
  /// In en, this message translates to:
  /// **'Wake up (Wake-on-LAN)'**
  String get systemWake;

  /// No description provided for @systemWakeSent.
  ///
  /// In en, this message translates to:
  /// **'Wake packet sent to {name}'**
  String systemWakeSent(String name);

  /// No description provided for @systemSuspend.
  ///
  /// In en, this message translates to:
  /// **'Sleep'**
  String get systemSuspend;

  /// No description provided for @systemReboot.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get systemReboot;

  /// No description provided for @systemPowerOff.
  ///
  /// In en, this message translates to:
  /// **'Shut down'**
  String get systemPowerOff;

  /// No description provided for @systemPowerConfirm.
  ///
  /// In en, this message translates to:
  /// **'{action} {host}?'**
  String systemPowerConfirm(String action, String host);

  /// No description provided for @systemPowerSent.
  ///
  /// In en, this message translates to:
  /// **'Sent: {action}'**
  String systemPowerSent(String action);

  /// No description provided for @systemServices.
  ///
  /// In en, this message translates to:
  /// **'Services'**
  String get systemServices;

  /// No description provided for @systemScopeUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get systemScopeUser;

  /// No description provided for @systemScopeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get systemScopeSystem;

  /// No description provided for @systemLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get systemLogs;

  /// No description provided for @systemRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get systemRestart;

  /// No description provided for @systemStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get systemStart;

  /// No description provided for @systemStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get systemStop;

  /// No description provided for @systemDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get systemDone;

  /// No description provided for @systemShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show all ({count})'**
  String systemShowAll(int count);

  /// No description provided for @agentUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Agent unreachable (is the PC on and Tailscale connected?)'**
  String get agentUnreachable;

  /// No description provided for @agentTls.
  ///
  /// In en, this message translates to:
  /// **'Secure connection failed'**
  String get agentTls;

  /// No description provided for @agentBadToken.
  ///
  /// In en, this message translates to:
  /// **'The agent rejected this phone; pair again'**
  String get agentBadToken;

  /// No description provided for @agentWrongTailnetUser.
  ///
  /// In en, this message translates to:
  /// **'This Tailscale account is not allowed on the agent'**
  String get agentWrongTailnetUser;

  /// No description provided for @agentPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Not permitted (system services need root)'**
  String get agentPermissionDenied;

  /// No description provided for @agentFeatureOff.
  ///
  /// In en, this message translates to:
  /// **'This feature is turned off on the agent'**
  String get agentFeatureOff;

  /// No description provided for @pairScanTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair with agent'**
  String get pairScanTitle;

  /// No description provided for @pairScanHint.
  ///
  /// In en, this message translates to:
  /// **'On the server run: tiphys-agent pair --name \"Phone\" and scan the QR code'**
  String get pairScanHint;

  /// No description provided for @pairNotTiphys.
  ///
  /// In en, this message translates to:
  /// **'This is not a Tiphys pairing code'**
  String get pairNotTiphys;

  /// No description provided for @pairWithQr.
  ///
  /// In en, this message translates to:
  /// **'Pair with QR code'**
  String get pairWithQr;

  /// No description provided for @agentSettings.
  ///
  /// In en, this message translates to:
  /// **'Agent settings'**
  String get agentSettings;

  /// No description provided for @agentFeatures.
  ///
  /// In en, this message translates to:
  /// **'Features'**
  String get agentFeatures;

  /// No description provided for @agentRestartHint.
  ///
  /// In en, this message translates to:
  /// **'Feature changes apply after the agent restarts.'**
  String get agentRestartHint;

  /// No description provided for @agentRestartRequired.
  ///
  /// In en, this message translates to:
  /// **'Saved. Restart the agent to apply feature changes.'**
  String get agentRestartRequired;

  /// No description provided for @agentAllowedRoots.
  ///
  /// In en, this message translates to:
  /// **'Allowed folders'**
  String get agentAllowedRoots;

  /// No description provided for @agentAllowedRootsHint.
  ///
  /// In en, this message translates to:
  /// **'One per line. Claude and file actions stay inside these.'**
  String get agentAllowedRootsHint;

  /// No description provided for @agentDevices.
  ///
  /// In en, this message translates to:
  /// **'Paired devices'**
  String get agentDevices;

  /// No description provided for @agentRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke'**
  String get agentRevoke;

  /// No description provided for @agentRevokeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Revoke access for {name}?'**
  String agentRevokeConfirm(String name);

  /// No description provided for @agentLockAll.
  ///
  /// In en, this message translates to:
  /// **'Lock everything'**
  String get agentLockAll;

  /// No description provided for @agentLockAllHint.
  ///
  /// In en, this message translates to:
  /// **'Revokes every paired device, including this phone. Pair again on the server to get back in.'**
  String get agentLockAllHint;

  /// No description provided for @agentLockAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'Revoke all devices on this agent, including this phone?'**
  String get agentLockAllConfirm;

  /// No description provided for @agentFeatSystem.
  ///
  /// In en, this message translates to:
  /// **'System metrics'**
  String get agentFeatSystem;

  /// No description provided for @agentFeatServices.
  ///
  /// In en, this message translates to:
  /// **'systemd services'**
  String get agentFeatServices;

  /// No description provided for @agentFeatWatch.
  ///
  /// In en, this message translates to:
  /// **'Watch hosts (offline alerts)'**
  String get agentFeatWatch;

  /// No description provided for @claudeLive.
  ///
  /// In en, this message translates to:
  /// **'Open sessions'**
  String get claudeLive;

  /// No description provided for @claudeHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get claudeHistory;

  /// No description provided for @claudeContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get claudeContinue;

  /// No description provided for @claudeStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get claudeStart;

  /// No description provided for @claudeFolder.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get claudeFolder;

  /// No description provided for @claudeChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose'**
  String get claudeChooseFolder;

  /// No description provided for @claudePromptHint.
  ///
  /// In en, this message translates to:
  /// **'What should Claude do?'**
  String get claudePromptHint;

  /// No description provided for @claudeQueueHint.
  ///
  /// In en, this message translates to:
  /// **'Add a message to the queue…'**
  String get claudeQueueHint;

  /// No description provided for @claudeModeBypassShort.
  ///
  /// In en, this message translates to:
  /// **'Don\'t ask'**
  String get claudeModeBypassShort;

  /// No description provided for @claudeModeAcceptShort.
  ///
  /// In en, this message translates to:
  /// **'Accept edits'**
  String get claudeModeAcceptShort;

  /// No description provided for @claudeModeDefaultShort.
  ///
  /// In en, this message translates to:
  /// **'Ask'**
  String get claudeModeDefaultShort;

  /// No description provided for @claudeStatusRunning.
  ///
  /// In en, this message translates to:
  /// **'working'**
  String get claudeStatusRunning;

  /// No description provided for @claudeStatusWaiting.
  ///
  /// In en, this message translates to:
  /// **'waiting for you'**
  String get claudeStatusWaiting;

  /// No description provided for @claudeStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'done'**
  String get claudeStatusIdle;

  /// No description provided for @claudeStatusError.
  ///
  /// In en, this message translates to:
  /// **'error'**
  String get claudeStatusError;

  /// No description provided for @claudeStatusStopped.
  ///
  /// In en, this message translates to:
  /// **'closed'**
  String get claudeStatusStopped;

  /// No description provided for @claudeThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking'**
  String get claudeThinking;

  /// No description provided for @claudePermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Claude wants to use {tool}'**
  String claudePermissionTitle(String tool);

  /// No description provided for @claudeAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get claudeAllow;

  /// No description provided for @claudeDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get claudeDeny;

  /// No description provided for @claudeAllowed.
  ///
  /// In en, this message translates to:
  /// **'Allowed'**
  String get claudeAllowed;

  /// No description provided for @claudeDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied'**
  String get claudeDenied;

  /// No description provided for @claudeResultLine.
  ///
  /// In en, this message translates to:
  /// **'{turns} turns · {seconds} s'**
  String claudeResultLine(int turns, int seconds);

  /// No description provided for @claudeWorking.
  ///
  /// In en, this message translates to:
  /// **'Claude is working…'**
  String get claudeWorking;

  /// No description provided for @claudeSlashCommands.
  ///
  /// In en, this message translates to:
  /// **'Slash commands'**
  String get claudeSlashCommands;

  /// No description provided for @claudeStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get claudeStop;

  /// No description provided for @claudeSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get claudeSend;

  /// No description provided for @claudeEndSession.
  ///
  /// In en, this message translates to:
  /// **'End session'**
  String get claudeEndSession;

  /// No description provided for @integrationAuthFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign-in rejected (check the token)'**
  String get integrationAuthFailed;

  /// No description provided for @siteUp.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get siteUp;

  /// No description provided for @siteDown.
  ///
  /// In en, this message translates to:
  /// **'Down'**
  String get siteDown;

  /// No description provided for @siteMaintenance.
  ///
  /// In en, this message translates to:
  /// **'Maintenance'**
  String get siteMaintenance;

  /// No description provided for @sitePaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get sitePaused;

  /// No description provided for @sitePending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get sitePending;

  /// No description provided for @sitesAllUp.
  ///
  /// In en, this message translates to:
  /// **'All {count} sites are up'**
  String sitesAllUp(int count);

  /// No description provided for @sitesSomeDown.
  ///
  /// In en, this message translates to:
  /// **'{count} down'**
  String sitesSomeDown(int count);

  /// No description provided for @siteAdd.
  ///
  /// In en, this message translates to:
  /// **'Add site'**
  String get siteAdd;

  /// No description provided for @siteDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Stop monitoring {name}? Its history is deleted too.'**
  String siteDeleteConfirm(String name);

  /// No description provided for @sitePause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get sitePause;

  /// No description provided for @siteResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get siteResume;

  /// No description provided for @sitePing.
  ///
  /// In en, this message translates to:
  /// **'Response'**
  String get sitePing;

  /// No description provided for @sitePingChart.
  ///
  /// In en, this message translates to:
  /// **'Response time chart'**
  String get sitePingChart;

  /// No description provided for @siteIncidents.
  ///
  /// In en, this message translates to:
  /// **'Outages and recoveries'**
  String get siteIncidents;

  /// No description provided for @siteNoIncidents.
  ///
  /// In en, this message translates to:
  /// **'No outages recorded'**
  String get siteNoIncidents;

  /// No description provided for @siteType.
  ///
  /// In en, this message translates to:
  /// **'Check type'**
  String get siteType;

  /// No description provided for @siteKeyword.
  ///
  /// In en, this message translates to:
  /// **'Keyword'**
  String get siteKeyword;

  /// No description provided for @siteNotifyNote.
  ///
  /// In en, this message translates to:
  /// **'Down and back-up alerts go to your phone through ntfy (topic: siteler).'**
  String get siteNotifyNote;

  /// No description provided for @daysShort.
  ///
  /// In en, this message translates to:
  /// **'d'**
  String get daysShort;

  /// No description provided for @hoursShort.
  ///
  /// In en, this message translates to:
  /// **'h'**
  String get hoursShort;

  /// No description provided for @dozzlePause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get dozzlePause;

  /// No description provided for @dozzleResume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get dozzleResume;

  /// No description provided for @dozzleBuffered.
  ///
  /// In en, this message translates to:
  /// **'{count} new lines waiting'**
  String dozzleBuffered(int count);

  /// No description provided for @dozzleNoLogs.
  ///
  /// In en, this message translates to:
  /// **'No log lines'**
  String get dozzleNoLogs;

  /// No description provided for @homepageOpenReal.
  ///
  /// In en, this message translates to:
  /// **'Open Homepage in the browser'**
  String get homepageOpenReal;

  /// No description provided for @homepageDown.
  ///
  /// In en, this message translates to:
  /// **'Not responding: {names}'**
  String homepageDown(String names);

  /// No description provided for @grafanaAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get grafanaAll;

  /// No description provided for @grafanaOpenPanel.
  ///
  /// In en, this message translates to:
  /// **'{type} panel: open in browser'**
  String grafanaOpenPanel(String type);

  /// No description provided for @dozzleRunning.
  ///
  /// In en, this message translates to:
  /// **'running'**
  String get dozzleRunning;

  /// No description provided for @dozzleStopped.
  ///
  /// In en, this message translates to:
  /// **'stopped or unhealthy'**
  String get dozzleStopped;

  /// No description provided for @notifClaudeDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Claude finished'**
  String get notifClaudeDoneTitle;

  /// No description provided for @notifClaudeWaitingTitle.
  ///
  /// In en, this message translates to:
  /// **'Claude needs your approval'**
  String get notifClaudeWaitingTitle;

  /// No description provided for @notifClaudeWaitingBody.
  ///
  /// In en, this message translates to:
  /// **'{title} · wants to use {tool}'**
  String notifClaudeWaitingBody(String title, String tool);

  /// No description provided for @notifClaudeErrorTitle.
  ///
  /// In en, this message translates to:
  /// **'Claude stopped with an error'**
  String get notifClaudeErrorTitle;

  /// No description provided for @notifHostOfflineTitle.
  ///
  /// In en, this message translates to:
  /// **'{host} is offline'**
  String notifHostOfflineTitle(String host);

  /// No description provided for @notifHostOfflineBody.
  ///
  /// In en, this message translates to:
  /// **'No answer for {minutes} min'**
  String notifHostOfflineBody(int minutes);

  /// No description provided for @notifHostOnlineTitle.
  ///
  /// In en, this message translates to:
  /// **'{host} is back online'**
  String notifHostOnlineTitle(String host);

  /// No description provided for @notifTestTitle.
  ///
  /// In en, this message translates to:
  /// **'Tiphys test notification'**
  String get notifTestTitle;

  /// No description provided for @pushThisPhone.
  ///
  /// In en, this message translates to:
  /// **'This phone'**
  String get pushThisPhone;

  /// No description provided for @pushEnable.
  ///
  /// In en, this message translates to:
  /// **'Turn on notifications'**
  String get pushEnable;

  /// No description provided for @pushEnabled.
  ///
  /// In en, this message translates to:
  /// **'Notifications are on'**
  String get pushEnabled;

  /// No description provided for @pushNoDistributor.
  ///
  /// In en, this message translates to:
  /// **'Install the ntfy app first, set its default server to your own ntfy server (e.g. :2586) and sign in. Tiphys then receives notifications through it, without Google.'**
  String get pushNoDistributor;

  /// No description provided for @pushChooseDistributor.
  ///
  /// In en, this message translates to:
  /// **'Deliver through'**
  String get pushChooseDistributor;

  /// No description provided for @pushRegistered.
  ///
  /// In en, this message translates to:
  /// **'Registered with: {hosts}'**
  String pushRegistered(String hosts);

  /// No description provided for @pushSendTest.
  ///
  /// In en, this message translates to:
  /// **'Send a test notification'**
  String get pushSendTest;

  /// No description provided for @pushDisable.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get pushDisable;

  /// No description provided for @pushSitesTopic.
  ///
  /// In en, this message translates to:
  /// **'Site alerts (Uptime Kuma) come to the ntfy app directly: subscribe to the siteler topic there.'**
  String get pushSitesTopic;

  /// No description provided for @pushOpenNtfy.
  ///
  /// In en, this message translates to:
  /// **'Subscribe in ntfy'**
  String get pushOpenNtfy;

  /// No description provided for @grafanaNoAlerts.
  ///
  /// In en, this message translates to:
  /// **'No active alerts'**
  String get grafanaNoAlerts;

  /// No description provided for @grafanaFiring.
  ///
  /// In en, this message translates to:
  /// **'Firing'**
  String get grafanaFiring;

  /// No description provided for @grafanaPending.
  ///
  /// In en, this message translates to:
  /// **'Pending'**
  String get grafanaPending;

  /// No description provided for @grafanaNoData.
  ///
  /// In en, this message translates to:
  /// **'No data'**
  String get grafanaNoData;

  /// No description provided for @grafanaNormal.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get grafanaNormal;

  /// No description provided for @agentPathNotAllowed.
  ///
  /// In en, this message translates to:
  /// **'This folder is outside the agent\'s allowed roots'**
  String get agentPathNotAllowed;

  /// No description provided for @auditEmpty.
  ///
  /// In en, this message translates to:
  /// **'No actions recorded yet'**
  String get auditEmpty;

  /// No description provided for @claudeAttachImage.
  ///
  /// In en, this message translates to:
  /// **'Attach photo'**
  String get claudeAttachImage;

  /// No description provided for @claudeRemoveImage.
  ///
  /// In en, this message translates to:
  /// **'Remove photo'**
  String get claudeRemoveImage;

  /// No description provided for @claudeUsageSemantics.
  ///
  /// In en, this message translates to:
  /// **'Usage: {usage}'**
  String claudeUsageSemantics(String usage);

  /// No description provided for @clipboardCopiedPhone.
  ///
  /// In en, this message translates to:
  /// **'Copied to phone clipboard'**
  String get clipboardCopiedPhone;

  /// No description provided for @clipboardCopyPhone.
  ///
  /// In en, this message translates to:
  /// **'Copy to phone'**
  String get clipboardCopyPhone;

  /// No description provided for @clipboardFromPc.
  ///
  /// In en, this message translates to:
  /// **'Get from PC'**
  String get clipboardFromPc;

  /// No description provided for @clipboardPastePhone.
  ///
  /// In en, this message translates to:
  /// **'Paste from phone'**
  String get clipboardPastePhone;

  /// No description provided for @clipboardPcContent.
  ///
  /// In en, this message translates to:
  /// **'PC clipboard'**
  String get clipboardPcContent;

  /// No description provided for @clipboardSent.
  ///
  /// In en, this message translates to:
  /// **'Sent to PC clipboard'**
  String get clipboardSent;

  /// No description provided for @clipboardToPc.
  ///
  /// In en, this message translates to:
  /// **'Send to PC'**
  String get clipboardToPc;

  /// No description provided for @commonCreate.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get commonCreate;

  /// No description provided for @commonNothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get commonNothingFound;

  /// No description provided for @durationHours.
  ///
  /// In en, this message translates to:
  /// **'{n} h'**
  String durationHours(int n);

  /// No description provided for @durationMinutes.
  ///
  /// In en, this message translates to:
  /// **'{n} min'**
  String durationMinutes(int n);

  /// No description provided for @editorChangedOnDisk.
  ///
  /// In en, this message translates to:
  /// **'The file changed on the computer since you opened it. Overwrite it with your version?'**
  String get editorChangedOnDisk;

  /// No description provided for @editorDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get editorDiscard;

  /// No description provided for @editorDiscardChanges.
  ///
  /// In en, this message translates to:
  /// **'Discard unsaved changes?'**
  String get editorDiscardChanges;

  /// No description provided for @editorNotText.
  ///
  /// In en, this message translates to:
  /// **'This file is not text (or is larger than 1 MB), so it can\'t be edited here.'**
  String get editorNotText;

  /// No description provided for @editorOverwrite.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get editorOverwrite;

  /// No description provided for @editorSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get editorSaved;

  /// No description provided for @editorWrap.
  ///
  /// In en, this message translates to:
  /// **'Wrap lines'**
  String get editorWrap;

  /// No description provided for @filesEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get filesEdit;

  /// No description provided for @gitBranches.
  ///
  /// In en, this message translates to:
  /// **'Branches'**
  String get gitBranches;

  /// No description provided for @gitChanges.
  ///
  /// In en, this message translates to:
  /// **'Changes ({n})'**
  String gitChanges(int n);

  /// No description provided for @gitClean.
  ///
  /// In en, this message translates to:
  /// **'No changes, working tree is clean'**
  String get gitClean;

  /// No description provided for @gitCommitAll.
  ///
  /// In en, this message translates to:
  /// **'Commit all changes'**
  String get gitCommitAll;

  /// No description provided for @gitCommitMessage.
  ///
  /// In en, this message translates to:
  /// **'Commit message'**
  String get gitCommitMessage;

  /// No description provided for @gitCommitStaged.
  ///
  /// In en, this message translates to:
  /// **'Commit {n} staged'**
  String gitCommitStaged(int n);

  /// No description provided for @gitCommitted.
  ///
  /// In en, this message translates to:
  /// **'Committed'**
  String get gitCommitted;

  /// No description provided for @gitDetached.
  ///
  /// In en, this message translates to:
  /// **'(detached HEAD)'**
  String get gitDetached;

  /// No description provided for @gitDiffTruncated.
  ///
  /// In en, this message translates to:
  /// **'Diff is too long; only the first 512 KB is shown.'**
  String get gitDiffTruncated;

  /// No description provided for @gitDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard changes'**
  String get gitDiscard;

  /// No description provided for @gitDiscardConfirm.
  ///
  /// In en, this message translates to:
  /// **'Discard all changes in {file}? This can\'t be undone.'**
  String gitDiscardConfirm(String file);

  /// No description provided for @gitFetch.
  ///
  /// In en, this message translates to:
  /// **'Fetch'**
  String get gitFetch;

  /// No description provided for @gitHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get gitHistory;

  /// No description provided for @gitMessageRequired.
  ///
  /// In en, this message translates to:
  /// **'Write a commit message'**
  String get gitMessageRequired;

  /// No description provided for @gitNewBranch.
  ///
  /// In en, this message translates to:
  /// **'New branch'**
  String get gitNewBranch;

  /// No description provided for @gitNoCommits.
  ///
  /// In en, this message translates to:
  /// **'No commits yet'**
  String get gitNoCommits;

  /// No description provided for @gitNoDiff.
  ///
  /// In en, this message translates to:
  /// **'No differences'**
  String get gitNoDiff;

  /// No description provided for @gitNothingToCommit.
  ///
  /// In en, this message translates to:
  /// **'Nothing to commit'**
  String get gitNothingToCommit;

  /// No description provided for @gitNotRepo.
  ///
  /// In en, this message translates to:
  /// **'This folder is not a Git repository'**
  String get gitNotRepo;

  /// No description provided for @gitPull.
  ///
  /// In en, this message translates to:
  /// **'Pull'**
  String get gitPull;

  /// No description provided for @gitPullFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t fetch from the remote'**
  String get gitPullFailed;

  /// No description provided for @gitPush.
  ///
  /// In en, this message translates to:
  /// **'Push'**
  String get gitPush;

  /// No description provided for @gitPushFailed.
  ///
  /// In en, this message translates to:
  /// **'Push failed'**
  String get gitPushFailed;

  /// No description provided for @gitRemoteBranches.
  ///
  /// In en, this message translates to:
  /// **'Remote branches'**
  String get gitRemoteBranches;

  /// No description provided for @gitStage.
  ///
  /// In en, this message translates to:
  /// **'Stage'**
  String get gitStage;

  /// No description provided for @gitStageAll.
  ///
  /// In en, this message translates to:
  /// **'Stage all'**
  String get gitStageAll;

  /// No description provided for @gitStaged.
  ///
  /// In en, this message translates to:
  /// **'Staged'**
  String get gitStaged;

  /// No description provided for @gitSwitched.
  ///
  /// In en, this message translates to:
  /// **'Switched to {branch}'**
  String gitSwitched(String branch);

  /// No description provided for @gitUnstage.
  ///
  /// In en, this message translates to:
  /// **'Unstage'**
  String get gitUnstage;

  /// No description provided for @gitUnstaged.
  ///
  /// In en, this message translates to:
  /// **'Not staged'**
  String get gitUnstaged;

  /// No description provided for @maintenanceActive.
  ///
  /// In en, this message translates to:
  /// **'In maintenance'**
  String get maintenanceActive;

  /// No description provided for @maintenanceAdd.
  ///
  /// In en, this message translates to:
  /// **'New maintenance window'**
  String get maintenanceAdd;

  /// No description provided for @maintenanceDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete maintenance window \"{name}\"?'**
  String maintenanceDeleteConfirm(String name);

  /// No description provided for @maintenanceDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration (starts now)'**
  String get maintenanceDuration;

  /// No description provided for @maintenanceEmpty.
  ///
  /// In en, this message translates to:
  /// **'No maintenance windows'**
  String get maintenanceEmpty;

  /// No description provided for @maintenanceEnded.
  ///
  /// In en, this message translates to:
  /// **'Ended'**
  String get maintenanceEnded;

  /// No description provided for @maintenanceExplain.
  ///
  /// In en, this message translates to:
  /// **'During a maintenance window, downtime of the selected sites is not alerted.'**
  String get maintenanceExplain;

  /// No description provided for @maintenanceInactive.
  ///
  /// In en, this message translates to:
  /// **'Inactive'**
  String get maintenanceInactive;

  /// No description provided for @maintenanceName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get maintenanceName;

  /// No description provided for @maintenanceNeedsSites.
  ///
  /// In en, this message translates to:
  /// **'Enter a name and pick at least one site'**
  String get maintenanceNeedsSites;

  /// No description provided for @maintenanceScheduled.
  ///
  /// In en, this message translates to:
  /// **'Scheduled'**
  String get maintenanceScheduled;

  /// No description provided for @maintenanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Maintenance windows'**
  String get maintenanceTitle;

  /// No description provided for @portsExplain.
  ///
  /// In en, this message translates to:
  /// **'Ports listening only on localhost can be shared to your tailnet (not the internet) and opened on the phone.'**
  String get portsExplain;

  /// No description provided for @portsLocalOnly.
  ///
  /// In en, this message translates to:
  /// **'Local only ({address})'**
  String portsLocalOnly(String address);

  /// No description provided for @portsOpen.
  ///
  /// In en, this message translates to:
  /// **'Reachable over tailnet ({address})'**
  String portsOpen(String address);

  /// No description provided for @portsShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get portsShare;

  /// No description provided for @portsShareConfirm.
  ///
  /// In en, this message translates to:
  /// **'Share port {port} to your tailnet over HTTPS?'**
  String portsShareConfirm(int port);

  /// No description provided for @portsShared.
  ///
  /// In en, this message translates to:
  /// **'Shared to tailnet (HTTPS)'**
  String get portsShared;

  /// No description provided for @portsUnshare.
  ///
  /// In en, this message translates to:
  /// **'Stop sharing'**
  String get portsUnshare;

  /// No description provided for @processesByCpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get processesByCpu;

  /// No description provided for @processesByMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get processesByMemory;

  /// No description provided for @processesConfirm.
  ///
  /// In en, this message translates to:
  /// **'{action}: {name} ({pid})?'**
  String processesConfirm(String action, String name, int pid);

  /// No description provided for @processesKill.
  ///
  /// In en, this message translates to:
  /// **'Force kill'**
  String get processesKill;

  /// No description provided for @processesTerminate.
  ///
  /// In en, this message translates to:
  /// **'Terminate'**
  String get processesTerminate;

  /// No description provided for @quickActionNoOutput.
  ///
  /// In en, this message translates to:
  /// **'(no output)'**
  String get quickActionNoOutput;

  /// No description provided for @quickActionRun.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get quickActionRun;

  /// No description provided for @quickActionRunConfirm.
  ///
  /// In en, this message translates to:
  /// **'Run \"{name}\" on {host}?'**
  String quickActionRunConfirm(String name, String host);

  /// No description provided for @quickActionRunning.
  ///
  /// In en, this message translates to:
  /// **'Running…'**
  String get quickActionRunning;

  /// No description provided for @quickActionsTitle.
  ///
  /// In en, this message translates to:
  /// **'Quick actions'**
  String get quickActionsTitle;

  /// No description provided for @siteAddToHomepage.
  ///
  /// In en, this message translates to:
  /// **'Also add to Homepage'**
  String get siteAddToHomepage;

  /// No description provided for @siteCertExpiry.
  ///
  /// In en, this message translates to:
  /// **'SSL expiry warning'**
  String get siteCertExpiry;

  /// No description provided for @siteCertExpiryHint.
  ///
  /// In en, this message translates to:
  /// **'Notify before the certificate expires'**
  String get siteCertExpiryHint;

  /// No description provided for @siteHomepageFailed.
  ///
  /// In en, this message translates to:
  /// **'Site added, but Homepage couldn\'t be updated'**
  String get siteHomepageFailed;

  /// No description provided for @siteHomepageGroup.
  ///
  /// In en, this message translates to:
  /// **'Homepage group'**
  String get siteHomepageGroup;

  /// No description provided for @toolsAudit.
  ///
  /// In en, this message translates to:
  /// **'Activity log'**
  String get toolsAudit;

  /// No description provided for @toolsClipboard.
  ///
  /// In en, this message translates to:
  /// **'Clipboard'**
  String get toolsClipboard;

  /// No description provided for @toolsPorts.
  ///
  /// In en, this message translates to:
  /// **'Ports'**
  String get toolsPorts;

  /// No description provided for @toolsPortsHint.
  ///
  /// In en, this message translates to:
  /// **'Open dev servers on the phone'**
  String get toolsPortsHint;

  /// No description provided for @toolsProcesses.
  ///
  /// In en, this message translates to:
  /// **'Processes'**
  String get toolsProcesses;

  /// No description provided for @toolsScreenshot.
  ///
  /// In en, this message translates to:
  /// **'Screenshot'**
  String get toolsScreenshot;

  /// No description provided for @toolsScreenshotRetake.
  ///
  /// In en, this message translates to:
  /// **'Take again'**
  String get toolsScreenshotRetake;

  /// No description provided for @toolsTitle.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get toolsTitle;

  /// No description provided for @voiceEmpty.
  ///
  /// In en, this message translates to:
  /// **'No speech recognized'**
  String get voiceEmpty;

  /// No description provided for @voiceNoPermission.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission is required'**
  String get voiceNoPermission;

  /// No description provided for @voiceRecord.
  ///
  /// In en, this message translates to:
  /// **'Voice message'**
  String get voiceRecord;

  /// No description provided for @voiceRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording {time}'**
  String voiceRecording(String time);

  /// No description provided for @voiceStop.
  ///
  /// In en, this message translates to:
  /// **'Stop and transcribe'**
  String get voiceStop;

  /// No description provided for @voiceTranscribing.
  ///
  /// In en, this message translates to:
  /// **'Transcribing…'**
  String get voiceTranscribing;

  /// No description provided for @notifDiskFullTitle.
  ///
  /// In en, this message translates to:
  /// **'{host}: disk almost full'**
  String notifDiskFullTitle(String host);

  /// No description provided for @notifDiskFullBody.
  ///
  /// In en, this message translates to:
  /// **'{mount} is {percent}% full'**
  String notifDiskFullBody(String mount, int percent);

  /// No description provided for @notifDiskOkTitle.
  ///
  /// In en, this message translates to:
  /// **'{host}: disk space OK again'**
  String notifDiskOkTitle(String host);

  /// No description provided for @notifServiceFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'{host}: service failed'**
  String notifServiceFailedTitle(String host);

  /// No description provided for @notifServiceRecoveredTitle.
  ///
  /// In en, this message translates to:
  /// **'{host}: service recovered'**
  String notifServiceRecoveredTitle(String host);

  /// No description provided for @notifGrafanaAlertTitle.
  ///
  /// In en, this message translates to:
  /// **'Alert: {name}'**
  String notifGrafanaAlertTitle(String name);

  /// No description provided for @notifGrafanaResolvedTitle.
  ///
  /// In en, this message translates to:
  /// **'Resolved: {name}'**
  String notifGrafanaResolvedTitle(String name);

  /// No description provided for @notifCommandDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'{host}: command finished'**
  String notifCommandDoneTitle(String host);

  /// No description provided for @notifCommandFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'{host}: command failed (exit {code})'**
  String notifCommandFailedTitle(String host, int code);

  /// No description provided for @notifCommandBody.
  ///
  /// In en, this message translates to:
  /// **'{command} · {seconds} s'**
  String notifCommandBody(String command, int seconds);

  /// No description provided for @agentAlerts.
  ///
  /// In en, this message translates to:
  /// **'Alerts (disk, services, Grafana)'**
  String get agentAlerts;

  /// No description provided for @agentAlertsDiskPercent.
  ///
  /// In en, this message translates to:
  /// **'Disk full threshold (%)'**
  String get agentAlertsDiskPercent;

  /// No description provided for @agentAlertsInterval.
  ///
  /// In en, this message translates to:
  /// **'Check every (seconds)'**
  String get agentAlertsInterval;

  /// No description provided for @agentAlertsFailedServices.
  ///
  /// In en, this message translates to:
  /// **'Notify when a systemd service fails'**
  String get agentAlertsFailedServices;

  /// No description provided for @agentAlertsGrafana.
  ///
  /// In en, this message translates to:
  /// **'Grafana alerts'**
  String get agentAlertsGrafana;

  /// No description provided for @agentAlertsDatasources.
  ///
  /// In en, this message translates to:
  /// **'Prometheus datasource UIDs'**
  String get agentAlertsDatasources;

  /// No description provided for @agentAlertsDatasourcesHint.
  ///
  /// In en, this message translates to:
  /// **'Comma separated; Grafana-managed alerts are always included'**
  String get agentAlertsDatasourcesHint;

  /// No description provided for @agentAlertsUseProfileGrafana.
  ///
  /// In en, this message translates to:
  /// **'Use Grafana from my profile'**
  String get agentAlertsUseProfileGrafana;

  /// No description provided for @agentFeatDesktop.
  ///
  /// In en, this message translates to:
  /// **'Desktop (clipboard, screenshot)'**
  String get agentFeatDesktop;

  /// No description provided for @agentFeatTranscribe.
  ///
  /// In en, this message translates to:
  /// **'Voice transcription'**
  String get agentFeatTranscribe;

  /// No description provided for @grafanaAlerts.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get grafanaAlerts;

  /// No description provided for @grafanaActiveOnly.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get grafanaActiveOnly;

  /// No description provided for @grafanaAllRules.
  ///
  /// In en, this message translates to:
  /// **'All rules'**
  String get grafanaAllRules;

  /// No description provided for @grafanaAllNormal.
  ///
  /// In en, this message translates to:
  /// **'All {n} rules are normal'**
  String grafanaAllNormal(int n);

  /// No description provided for @grafanaActiveAlerts.
  ///
  /// In en, this message translates to:
  /// **'{active} of {total} rules active'**
  String grafanaActiveAlerts(int active, int total);

  /// No description provided for @grafanaAlertsNote.
  ///
  /// In en, this message translates to:
  /// **'Phone notifications for these alerts come from the agent (Agent settings › Alerts).'**
  String get grafanaAlertsNote;

  /// No description provided for @dozzleShareLog.
  ///
  /// In en, this message translates to:
  /// **'Share log file'**
  String get dozzleShareLog;

  /// No description provided for @shareTitle.
  ///
  /// In en, this message translates to:
  /// **'Send to computer'**
  String get shareTitle;

  /// No description provided for @shareItems.
  ///
  /// In en, this message translates to:
  /// **'{n, plural, =1{1 item} other{{n} items}}'**
  String shareItems(int n);

  /// No description provided for @shareText.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get shareText;

  /// No description provided for @shareToHost.
  ///
  /// In en, this message translates to:
  /// **'Computer'**
  String get shareToHost;

  /// No description provided for @shareFolder.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get shareFolder;

  /// No description provided for @shareSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get shareSend;

  /// No description provided for @shareSent.
  ///
  /// In en, this message translates to:
  /// **'{n} item(s) sent to {host}'**
  String shareSent(int n, String host);

  /// No description provided for @claudeWorktree.
  ///
  /// In en, this message translates to:
  /// **'Separate git worktree'**
  String get claudeWorktree;

  /// No description provided for @claudeWorktreeHint.
  ///
  /// In en, this message translates to:
  /// **'New branch in a sibling folder; your working copy stays untouched'**
  String get claudeWorktreeHint;

  /// No description provided for @agentNoDisplay.
  ///
  /// In en, this message translates to:
  /// **'No desktop session on the computer (nobody logged in?)'**
  String get agentNoDisplay;

  /// No description provided for @agentPortPublic.
  ///
  /// In en, this message translates to:
  /// **'This port is already reachable over the tailnet'**
  String get agentPortPublic;

  /// No description provided for @grafanaExplore.
  ///
  /// In en, this message translates to:
  /// **'Quick query'**
  String get grafanaExplore;

  /// No description provided for @grafanaExploreHint.
  ///
  /// In en, this message translates to:
  /// **'PromQL / LogQL, like Explore'**
  String get grafanaExploreHint;

  /// No description provided for @grafanaExploreEmpty.
  ///
  /// In en, this message translates to:
  /// **'Write a query and run it'**
  String get grafanaExploreEmpty;

  /// No description provided for @grafanaNoDatasources.
  ///
  /// In en, this message translates to:
  /// **'No Prometheus or Loki datasource'**
  String get grafanaNoDatasources;

  /// No description provided for @grafanaRun.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get grafanaRun;

  /// No description provided for @filesShowAll.
  ///
  /// In en, this message translates to:
  /// **'Show {count} more'**
  String filesShowAll(int count);

  /// No description provided for @ntfyExplain.
  ///
  /// In en, this message translates to:
  /// **'Notifications arrive in the ntfy app on this phone; sign in to the server there (Settings › Manage users). The topics below become \"Open in ntfy\" shortcuts.'**
  String get ntfyExplain;

  /// No description provided for @scriberrExplain.
  ///
  /// In en, this message translates to:
  /// **'Voice messages are transcribed on the PC through the Tiphys agent, which holds the Scriberr key. Choose the language and model here.'**
  String get scriberrExplain;

  /// No description provided for @commonRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get commonRefresh;

  /// No description provided for @claudeInTerminalNote.
  ///
  /// In en, this message translates to:
  /// **'This session is open in a terminal on the PC. Read it here or take it over on the phone.'**
  String get claudeInTerminalNote;

  /// No description provided for @claudeTerminalSessions.
  ///
  /// In en, this message translates to:
  /// **'Open in terminal'**
  String get claudeTerminalSessions;

  /// No description provided for @claudeTerminalSessionsHint.
  ///
  /// In en, this message translates to:
  /// **'Claude Code sessions running on the PC outside Tiphys. Read-only here.'**
  String get claudeTerminalSessionsHint;

  /// No description provided for @claudePromptOptional.
  ///
  /// In en, this message translates to:
  /// **'First message (optional)'**
  String get claudePromptOptional;

  /// No description provided for @claudeUntitled.
  ///
  /// In en, this message translates to:
  /// **'New session'**
  String get claudeUntitled;

  /// No description provided for @claudeTakeover.
  ///
  /// In en, this message translates to:
  /// **'Take over on phone'**
  String get claudeTakeover;

  /// No description provided for @claudeTakeoverConfirm.
  ///
  /// In en, this message translates to:
  /// **'Claude in the PC terminal will be closed and this session continues here with its full history. To go back to the terminal later run:\nclaude --resume {id}'**
  String claudeTakeoverConfirm(String id);

  /// No description provided for @claudeTerminalBusy.
  ///
  /// In en, this message translates to:
  /// **'Claude is working in the terminal right now. Try again when it finishes.'**
  String get claudeTerminalBusy;

  /// No description provided for @claudeTerminalGone.
  ///
  /// In en, this message translates to:
  /// **'This session is no longer open in the terminal.'**
  String get claudeTerminalGone;

  /// No description provided for @claudeTerminalStuck.
  ///
  /// In en, this message translates to:
  /// **'The terminal session did not close. Close it on the PC and try again.'**
  String get claudeTerminalStuck;

  /// No description provided for @voiceTranscribingProgress.
  ///
  /// In en, this message translates to:
  /// **'Transcribing on the server · {secs} s / ~{estimate} s'**
  String voiceTranscribingProgress(int secs, int estimate);

  /// No description provided for @claudeRestored.
  ///
  /// In en, this message translates to:
  /// **'Agent restarted · continue where you left off'**
  String get claudeRestored;

  /// No description provided for @claudeCompacted.
  ///
  /// In en, this message translates to:
  /// **'Earlier part was summarized'**
  String get claudeCompacted;

  /// No description provided for @claudeSessionGone.
  ///
  /// In en, this message translates to:
  /// **'This session no longer exists. Open it from History to continue.'**
  String get claudeSessionGone;

  /// No description provided for @claudeReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Connection lost, reconnecting…'**
  String get claudeReconnecting;

  /// No description provided for @claudeOutboxWaiting.
  ///
  /// In en, this message translates to:
  /// **'waiting for connection'**
  String get claudeOutboxWaiting;

  /// No description provided for @claudeOutboxSending.
  ///
  /// In en, this message translates to:
  /// **'sending…'**
  String get claudeOutboxSending;

  /// No description provided for @claudeDecisionFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Could not send your decision'**
  String get claudeDecisionFailedTitle;

  /// No description provided for @claudeDecisionFailedBody.
  ///
  /// In en, this message translates to:
  /// **'Open Tiphys to answer the permission request.'**
  String get claudeDecisionFailedBody;

  /// No description provided for @agentSection.
  ///
  /// In en, this message translates to:
  /// **'Agent'**
  String get agentSection;

  /// No description provided for @agentVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get agentVersion;

  /// No description provided for @agentOutdated.
  ///
  /// In en, this message translates to:
  /// **'{version} · outdated'**
  String agentOutdated(String version);

  /// No description provided for @agentOutdatedHint.
  ///
  /// In en, this message translates to:
  /// **'This app expects agent {version}. Update it on the PC with tools/deploy-agent.sh (remote) or by rebuilding the agent (local).'**
  String agentOutdatedHint(String version);

  /// No description provided for @agentUptime.
  ///
  /// In en, this message translates to:
  /// **'Running for'**
  String get agentUptime;

  /// No description provided for @agentUptimeDays.
  ///
  /// In en, this message translates to:
  /// **'{days} d {hours} h'**
  String agentUptimeDays(int days, int hours);

  /// No description provided for @agentUptimeHours.
  ///
  /// In en, this message translates to:
  /// **'{hours} h {minutes} min'**
  String agentUptimeHours(int hours, int minutes);

  /// No description provided for @agentUptimeMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String agentUptimeMinutes(int minutes);

  /// No description provided for @agentMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get agentMemory;

  /// No description provided for @agentMemoryValue.
  ///
  /// In en, this message translates to:
  /// **'agent {agent} · Claude/commands {children}'**
  String agentMemoryValue(String agent, String children);

  /// No description provided for @agentRestarts.
  ///
  /// In en, this message translates to:
  /// **'Unexpected restarts'**
  String get agentRestarts;

  /// No description provided for @notifAgentRestartedTitle.
  ///
  /// In en, this message translates to:
  /// **'{host}: agent restarted unexpectedly'**
  String notifAgentRestartedTitle(String host);

  /// No description provided for @notifAgentRestartedBody.
  ///
  /// In en, this message translates to:
  /// **'It crashed or ran out of memory. Live Claude sessions were restored.'**
  String get notifAgentRestartedBody;

  /// No description provided for @agentRestartsWindow.
  ///
  /// In en, this message translates to:
  /// **'last 24 hours'**
  String get agentRestartsWindow;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'tr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'tr':
      return AppLocalizationsTr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
