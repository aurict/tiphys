// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Turkish (`tr`).
class AppLocalizationsTr extends AppLocalizations {
  AppLocalizationsTr([String locale = 'tr']) : super(locale);

  @override
  String get appName => 'Tiphys';

  @override
  String get tabHome => 'Ana';

  @override
  String get tabClaude => 'Claude';

  @override
  String get tabTerminal => 'Terminal';

  @override
  String get tabFiles => 'Dosyalar';

  @override
  String get tabSystem => 'Sistem';

  @override
  String get homeInfra => 'Altyapı';

  @override
  String homeOnlineCount(int online, int total) {
    return '$online/$total çevrimiçi';
  }

  @override
  String get homeNoHosts => 'Henüz host yok';

  @override
  String get homeAddHost => 'Ayarlar\'dan bir host ekle';

  @override
  String homeClaudeSessions(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'oturum',
      zero: 'oturum yok',
    );
    return '$_temp0';
  }

  @override
  String homeClaudeWaiting(int count) {
    return '$count onay bekliyor';
  }

  @override
  String get homeNewClaudeSession => 'Yeni Claude oturumu';

  @override
  String homeCpu(String percent) {
    return 'CPU $percent';
  }

  @override
  String homeRam(String percent) {
    return 'RAM $percent';
  }

  @override
  String get homeQuickAccess => 'Hızlı erişim';

  @override
  String get homeOpenInBrowser => 'tarayıcıda';

  @override
  String homeTabsCount(int count) {
    return '$count sekme';
  }

  @override
  String get homeLive => 'canlı';

  @override
  String get homeLastHour => 'CPU · 1 sa';

  @override
  String get homeNotConnected => 'bağlı değil';

  @override
  String get homeSearch => 'Ara';

  @override
  String get commonLoading => 'Yükleniyor…';

  @override
  String get commonRetry => 'Tekrar dene';

  @override
  String get commonSave => 'Kaydet';

  @override
  String get commonCancel => 'Vazgeç';

  @override
  String get commonDelete => 'Sil';

  @override
  String get commonAdd => 'Ekle';

  @override
  String get commonEdit => 'Düzenle';

  @override
  String get commonDone => 'Bitti';

  @override
  String get commonClose => 'Kapat';

  @override
  String get commonCopy => 'Kopyala';

  @override
  String get commonCopied => 'Kopyalandı';

  @override
  String get commonShare => 'Paylaş';

  @override
  String get commonConfirm => 'Onayla';

  @override
  String get commonContinue => 'Devam';

  @override
  String get commonTest => 'Bağlantıyı test et';

  @override
  String get commonTesting => 'Test ediliyor…';

  @override
  String get commonTestOk => 'Bağlantı çalışıyor';

  @override
  String commonTestFailed(String reason) {
    return 'Bağlantı kurulamadı: $reason';
  }

  @override
  String get commonOptional => 'isteğe bağlı';

  @override
  String get commonRequired => 'Zorunlu';

  @override
  String get commonNone => 'Yok';

  @override
  String get commonEmpty => 'Burada henüz bir şey yok';

  @override
  String get commonError => 'Bir şeyler ters gitti';

  @override
  String get commonUnsaved => 'Kaydedilmemiş değişiklikler var';

  @override
  String get commonDiscard => 'Vazgeç ve çık';

  @override
  String get commonOn => 'Açık';

  @override
  String get commonOff => 'Kapalı';

  @override
  String get settingsTitle => 'Ayarlar';

  @override
  String get settingsHosts => 'Hostlar';

  @override
  String get settingsHostsHint =>
      'Sunucular ve PC: adres, SSH, ajan, uyandırma';

  @override
  String get settingsKeys => 'Anahtarlar ve şifreler';

  @override
  String get settingsKeysHint => 'SSH anahtarları, API token\'ları, şifreler';

  @override
  String get settingsClaude => 'Claude';

  @override
  String get settingsClaudeHint =>
      'Ajan, varsayılanlar, profiller, favori klasörler';

  @override
  String get settingsIntegrations => 'Entegrasyonlar';

  @override
  String get settingsIntegrationsHint =>
      'Grafana, Dozzle, Homepage, Uptime Kuma, ntfy, Scriberr';

  @override
  String get settingsTerminal => 'Terminal';

  @override
  String get settingsTerminalHint =>
      'Yazı tipi, tuş çubuğu, komut parçacıkları';

  @override
  String get settingsFiles => 'Dosyalar';

  @override
  String get settingsFilesHint => 'Yer imleri, gizli dosyalar';

  @override
  String get settingsQuickActions => 'Hızlı işlemler';

  @override
  String get settingsQuickActionsHint => 'Tek dokunuşluk kendi komutların';

  @override
  String get settingsHome => 'Ana ekran';

  @override
  String get settingsHomeHint => 'Kartlar ve sıraları';

  @override
  String get settingsAppearance => 'Görünüm';

  @override
  String get settingsAppearanceHint => 'Tema ve dil';

  @override
  String get settingsSecurity => 'Güvenlik';

  @override
  String get settingsSecurityHint => 'Parmak izi, PIN, otomatik kilit';

  @override
  String get settingsProfile => 'Profil dosyası';

  @override
  String get settingsProfileHint => 'İçe aktar, dışa aktar, sıfırla';

  @override
  String get settingsNotifications => 'Bildirimler';

  @override
  String get settingsNotificationsHint => 'Neler için haber verilsin';

  @override
  String get appearanceTheme => 'Tema';

  @override
  String get appearanceThemeSystem => 'Sistem';

  @override
  String get appearanceThemeLight => 'Açık';

  @override
  String get appearanceThemeDark => 'Koyu';

  @override
  String get appearanceLanguage => 'Dil';

  @override
  String get appearanceLanguageSystem => 'Sistem dili';

  @override
  String get appearanceLanguageTr => 'Türkçe';

  @override
  String get appearanceLanguageEn => 'English';

  @override
  String get hostsEmpty => 'Host yok. PC\'ni ve sunucularını ekle.';

  @override
  String get hostAdd => 'Host ekle';

  @override
  String get hostEdit => 'Hostu düzenle';

  @override
  String get hostId => 'Kimlik';

  @override
  String get hostIdHint => 'küçük harf, ör. atlas';

  @override
  String get hostName => 'Ad';

  @override
  String get hostColor => 'Renk';

  @override
  String get hostAddress => 'Adres';

  @override
  String get hostAddressHint => 'Tailscale adı ya da IP';

  @override
  String get hostSsh => 'SSH';

  @override
  String get hostSshPort => 'Port';

  @override
  String get hostSshUser => 'Kullanıcı';

  @override
  String get hostSshAuth => 'Giriş yöntemi';

  @override
  String get hostSshAuthKey => 'SSH anahtarı';

  @override
  String get hostSshAuthPassword => 'Şifre';

  @override
  String get hostSshKey => 'Anahtar';

  @override
  String get hostSshPassword => 'Şifre';

  @override
  String get hostTmux => 'tmux oturumu';

  @override
  String get hostAgent => 'Tiphys ajanı';

  @override
  String get hostAgentUrl => 'Ajan adresi';

  @override
  String get hostAgentToken => 'Ajan token\'ı';

  @override
  String get hostAgentNone => 'Bu hostta ajan yok';

  @override
  String get hostWake => 'Wake-on-LAN';

  @override
  String get hostWakeMac => 'MAC adresi';

  @override
  String get hostWakeVia => 'Gönderen';

  @override
  String get hostTags => 'Etiketler';

  @override
  String hostDeleteConfirm(String name) {
    return '$name silinsin mi? Bu hostu kullanan ayarlar onu kaybeder.';
  }

  @override
  String get keysEmpty => 'Henüz anahtar ya da şifre yok.';

  @override
  String get keysSshKeys => 'SSH anahtarları';

  @override
  String get keysTokens => 'Token\'lar ve şifreler';

  @override
  String get keyImportFile => 'Dosyadan içe aktar';

  @override
  String get keyPaste => 'Anahtar yapıştır';

  @override
  String get keyGenerate => 'Bu telefonda üret';

  @override
  String get keyLabel => 'Etiket';

  @override
  String get keyPrivate => 'Özel anahtar';

  @override
  String get keyPassphrase => 'Anahtar parolası';

  @override
  String get keyPublic => 'Açık anahtar';

  @override
  String get keyCopyPublic => 'Açık anahtarı kopyala';

  @override
  String get keyInstallOnHost => 'Bir hostun authorized_keys dosyasına ekle';

  @override
  String get keyInvalid => 'Bu bir SSH özel anahtarına benzemiyor';

  @override
  String get keyGenerated => 'Anahtar üretildi';

  @override
  String get secretAdd => 'Şifre ekle';

  @override
  String get secretValue => 'Değer';

  @override
  String get secretStoredSafely =>
      'Android Keystore\'da saklanır. Profil dosyasına asla düz metin olarak yazılmaz.';

  @override
  String secretMissing(String id) {
    return 'Eksik gizli bilgi: $id';
  }

  @override
  String get profileExport => 'Dışa aktar';

  @override
  String get profileExportPlain => 'Gizli bilgiler olmadan';

  @override
  String get profileExportPlainHint =>
      'Paylaşmak güvenli. Anahtar ve token\'lar dosyaya girmez.';

  @override
  String get profileExportEncrypted => 'Şifreli yedek';

  @override
  String get profileExportEncryptedHint =>
      'Anahtar ve token\'lar dahil, bir parolayla şifrelenir.';

  @override
  String get profileImport => 'İçe aktar';

  @override
  String get profileImportHint => 'Bir .tiphys.json dosyası seç';

  @override
  String get profileReset => 'Her şeyi sıfırla';

  @override
  String get profileResetConfirm =>
      'Bu telefondaki tüm ayarlar ve gizli bilgiler silinsin mi?';

  @override
  String get profilePassphrase => 'Parola';

  @override
  String get profilePassphraseRepeat => 'Parolayı tekrarla';

  @override
  String get profilePassphraseMismatch => 'Parolalar aynı değil';

  @override
  String get profilePassphraseShort => 'En az 10 karakter';

  @override
  String get profilePassphraseWrong => 'Parola yanlış ya da dosya bozuk';

  @override
  String get profileExported => 'Profil dışa aktarıldı';

  @override
  String get profileImported => 'Profil içe aktarıldı';

  @override
  String get profilePreviewTitle => 'Değişiklikleri incele';

  @override
  String get profilePreviewAdded => 'Eklenecek';

  @override
  String get profilePreviewChanged => 'Değişecek';

  @override
  String get profilePreviewRemoved => 'Silinecek';

  @override
  String get profilePreviewUnchanged => 'Değişiklik yok';

  @override
  String get profileModeMerge => 'Birleştir';

  @override
  String get profileModeMergeHint =>
      'Aynı kimlikler üzerine yazılır, yeniler eklenir, hiçbir şey silinmez.';

  @override
  String get profileModeReplace => 'Tamamen değiştir';

  @override
  String get profileModeReplaceHint => 'Her şey birebir dosyadaki hale gelir.';

  @override
  String get profileMissingSecrets => 'Yeniden girmen gereken gizli bilgiler';

  @override
  String get profileErrorFormat => 'Bu bir Tiphys profili değil';

  @override
  String profileErrorNewer(int version) {
    return 'Bu dosya Tiphys\'in daha yeni bir sürümüyle yapılmış (şema $version)';
  }

  @override
  String profileErrorInvalid(String details) {
    return 'Dosyada hatalar var: $details';
  }

  @override
  String get profileErrorJson => 'Dosya geçerli bir JSON değil';

  @override
  String get securityBiometric => 'Parmak iziyle aç';

  @override
  String get securityPin => 'PIN';

  @override
  String get securityPinSet => 'PIN belirle';

  @override
  String get securityPinChange => 'PIN\'i değiştir';

  @override
  String get securityPinEnter => 'PIN\'i gir';

  @override
  String get securityPinNew => 'Yeni PIN';

  @override
  String get securityPinRepeat => 'PIN\'i tekrarla';

  @override
  String get securityPinWrong => 'PIN yanlış';

  @override
  String get securityPinShort => 'En az 6 hane';

  @override
  String get securityAutoLock => 'Otomatik kilit';

  @override
  String securityAutoLockSeconds(int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      seconds,
      locale: localeName,
      other: '$seconds sn sonra',
      zero: 'Hemen',
    );
    return '$_temp0';
  }

  @override
  String get lockTitle => 'Tiphys kilitli';

  @override
  String get lockUnlock => 'Kilidi aç';

  @override
  String get lockBiometricReason => 'Tiphys\'in kilidini aç';

  @override
  String get homeCardsInfra => 'Altyapı';

  @override
  String get homeCardsClaude => 'Claude';

  @override
  String get homeCardsSystem => 'PC durumu';

  @override
  String get homeCardsGrafana => 'Grafana';

  @override
  String get homeCardsDozzle => 'Dozzle';

  @override
  String get homeCardsQuickAccess => 'Hızlı erişim';

  @override
  String comingInPhase(int phase) {
    return '$phase. fazda geliyor';
  }

  @override
  String get relativeNow => 'az önce';

  @override
  String relativeMinutes(int count) {
    return '$count dk önce';
  }

  @override
  String relativeHours(int count) {
    return '$count sa önce';
  }

  @override
  String relativeDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count gün önce',
      one: 'dün',
    );
    return '$_temp0';
  }

  @override
  String get claudeAgentHost => 'Claude\'u çalıştıran ajan';

  @override
  String get claudeModel => 'Model';

  @override
  String get claudeEffort => 'Düşünme seviyesi';

  @override
  String get claudePermissionMode => 'İzin modu';

  @override
  String get claudeModeBypass => 'İzin sormadan';

  @override
  String get claudeModeAcceptEdits => 'Düzenlemeleri kabul et, komutlarda sor';

  @override
  String get claudeModeDefault => 'Her seferinde sor';

  @override
  String get claudeModePlan => 'Önce plan';

  @override
  String get claudeProfiles => 'Profiller';

  @override
  String get claudeProfilesHint =>
      'Her satıra bir tane: kimlik = yapılandırma klasörü';

  @override
  String get claudeFavoriteFolders => 'Favori klasörler';

  @override
  String get claudePinnedCommands => 'Sabitlenmiş slash komutları';

  @override
  String durationSeconds(int seconds) {
    return '$seconds sn';
  }

  @override
  String get filesBookmarks => 'Yer imleri';

  @override
  String get filesBookmarksHint => 'Her satıra bir tane: host:yol';

  @override
  String get filesShowHidden => 'Gizli dosyaları göster';

  @override
  String get hostWakeViaHint =>
      'Uyandırma paketi PC\'nin bulunduğu yerel ağdan gönderilmelidir. \"Bu telefon\" seçeneği sadece telefon o Wi-Fi\'dayken çalışır.';

  @override
  String get hostWakeViaPhone => 'Bu telefon (aynı Wi-Fi)';

  @override
  String integrationAdd(String name) {
    return '$name ekle';
  }

  @override
  String get integrationOthers => 'Diğerleri';

  @override
  String get integrationNotSet => 'ayarlanmadı';

  @override
  String get integrationToken => 'Token kullan';

  @override
  String get integrationServiceAccountToken => 'Servis hesabı token\'ı';

  @override
  String get integrationAccessToken => 'Erişim token\'ı';

  @override
  String get integrationApiKey => 'API anahtarı';

  @override
  String get integrationLogin => 'Giriş gerekli';

  @override
  String get integrationDefaults => 'Varsayılanlar';

  @override
  String get integrationDefaultDashboard => 'Varsayılan dashboard UID\'i';

  @override
  String get integrationRefreshSeconds => 'Yenileme (sn)';

  @override
  String get integrationRange => 'Zaman aralığı';

  @override
  String get integrationBrowserUrl => 'Tarayıcı adresi';

  @override
  String get integrationReadVia => 'Okunacağı ajan';

  @override
  String get integrationServicesFile => 'services.yaml yolu';

  @override
  String get integrationOpenInApp => 'Servisleri uygulama içinde aç';

  @override
  String get integrationNeedsAgentHost =>
      'Önce Tiphys ajanı olan bir host ekle';

  @override
  String get integrationDeleteConfirm => 'Bu entegrasyon kaldırılsın mı?';

  @override
  String get notifyClaudeDone => 'Oturum bitince';

  @override
  String get notifyClaudeWaiting => 'Onay beklediğinde';

  @override
  String get notifyClaudeError => 'Hata verince';

  @override
  String get notifySiteDown => 'Site kesintileri';

  @override
  String get notifyPcOffline => 'PC çevrimdışı olunca';

  @override
  String get notifyServiceDown => 'Bir servis çökünce';

  @override
  String get notifyGrafana => 'Grafana alarmları';

  @override
  String get notifyDiskFull => 'Disk doluluk uyarısı';

  @override
  String get notifyLongCommand => 'Uzun süren komut bitince haber ver';

  @override
  String get ntfyTopics => 'Takip edilecek konular';

  @override
  String get ntfyTopicsHint =>
      'Virgülle ayır. Örn. Uptime Kuma uyarıları için siteler';

  @override
  String get quickActionCommand => 'Komut';

  @override
  String get quickActionConfirm => 'Çalıştırmadan önce sor';

  @override
  String get scriberrAutoDetect => 'Otomatik algıla';

  @override
  String get scriberrModel => 'Model';

  @override
  String get scriberrModelSmall => 'small (hızlı)';

  @override
  String get scriberrModelLarge => 'large-v3 (doğru)';

  @override
  String get secretNeedsValue => 'eksik';

  @override
  String get secretUnused => 'hiçbir ayar kullanmıyor';

  @override
  String get terminalFontSize => 'Yazı boyutu';

  @override
  String get terminalExtraKeys => 'Ek tuş çubuğu';

  @override
  String get terminalExtraKeysHint =>
      'Boşlukla ayır: esc tab ctrl alt up down left right | ~ /';

  @override
  String get terminalSnippets => 'Komut parçacıkları';

  @override
  String get terminalSnippetsHint =>
      'Her satıra bir tane: ad | komut | host (isteğe bağlı)';

  @override
  String get terminalThemeNote => 'Terminal renkleri uygulama temasını izler.';

  @override
  String get uptimeInterval => 'Kontrol aralığı (sn)';

  @override
  String get uptimeAlertAfter => 'Şu kadar kapalı kalınca uyar (sn)';

  @override
  String get uptimeCertDays => 'SSL bitişinden kaç gün önce uyar';

  @override
  String get uptimeCredentialsOnAgent =>
      'Uptime Kuma giriş bilgileri ajanda durur; telefonda saklanmaz.';

  @override
  String get uptimeNotifyRecovery => 'Site tekrar açılınca haber ver';

  @override
  String get sshNoSsh => 'Bu host için SSH ayarlı değil';

  @override
  String get sshUnreachable => 'Hosta ulaşılamıyor (Tailscale açık mı?)';

  @override
  String get sshAuthFailed =>
      'Giriş reddedildi: anahtarı ya da şifreyi kontrol et';

  @override
  String get sshTimeout => 'Bağlantı zaman aşımına uğradı';

  @override
  String get sshHostKeyChanged =>
      'Sunucu anahtarı değişmiş! Güvenlik için bağlantı durduruldu.';

  @override
  String sshConnecting(String name) {
    return '$name hostuna bağlanılıyor…';
  }

  @override
  String get sshDisconnected =>
      'Bağlantı koptu. tmux oturumu sunucuda çalışmaya devam ediyor.';

  @override
  String get sshReconnect => 'Yeniden bağlan';

  @override
  String terminalOpenOn(String name) {
    return '$name üzerinde yeni terminal';
  }

  @override
  String get terminalPickHost => 'Terminal açmak için yukarıdan bir host seç.';

  @override
  String get terminalNoSshHosts =>
      'Henüz SSH ayarlı host yok. Ayarlar › Hostlar bölümünden ekle.';

  @override
  String get filesUpload => 'Buraya yükle';

  @override
  String filesUploaded(String name) {
    return '$name yüklendi';
  }

  @override
  String get filesUp => 'Üst klasör';

  @override
  String get filesTerminalHere => 'Burada terminal';

  @override
  String get filesClaudeHere => 'Burada Claude';

  @override
  String get filesNewFolder => 'Yeni klasör';

  @override
  String get filesPasteHere => 'Buraya yapıştır';

  @override
  String get filesEmptyFolder => 'Bu klasör boş';

  @override
  String get filesPreview => 'Önizle';

  @override
  String get filesDownload => 'İndir / paylaş';

  @override
  String get filesRename => 'Yeniden adlandır';

  @override
  String get filesCopy => 'Kopyala';

  @override
  String get filesMove => 'Taşı';

  @override
  String get filesTrash => 'Çöp kutusuna taşı';

  @override
  String filesTrashConfirm(String name) {
    return '$name çöp kutusuna taşınsın mı? Masaüstündeki çöp kutusundan geri alabilirsin.';
  }

  @override
  String get filesTrashed => 'Çöp kutusuna taşındı';

  @override
  String get filesMore => 'Daha fazla';

  @override
  String get filesBinary => 'İkili dosya: açmak için indir';

  @override
  String get keyNeedsPassphrase => 'Bu anahtar parolalı; parolasını gir';

  @override
  String keyInstalled(String name) {
    return 'Anahtar $name hostuna eklendi';
  }

  @override
  String keyDeleteConfirm(String name) {
    return '$name anahtarı bu telefondan silinsin mi?';
  }

  @override
  String get systemMonitoring => 'İzleme';

  @override
  String get systemSites => 'Siteler (Uptime Kuma)';

  @override
  String systemUptime(int days, int hours) {
    return '$days gün $hours sa açık';
  }

  @override
  String get systemDisk => 'Disk';

  @override
  String get systemPower => 'Güç';

  @override
  String get systemWake => 'Uyandır (Wake-on-LAN)';

  @override
  String systemWakeSent(String name) {
    return '$name için uyandırma paketi gönderildi';
  }

  @override
  String get systemSuspend => 'Uyku';

  @override
  String get systemReboot => 'Yeniden başlat';

  @override
  String get systemPowerOff => 'Kapat';

  @override
  String systemPowerConfirm(String action, String host) {
    return '$host: $action?';
  }

  @override
  String systemPowerSent(String action) {
    return 'Gönderildi: $action';
  }

  @override
  String get systemServices => 'Servisler';

  @override
  String get systemScopeUser => 'Kullanıcı';

  @override
  String get systemScopeSystem => 'Sistem';

  @override
  String get systemLogs => 'Loglar';

  @override
  String get systemRestart => 'Yeniden başlat';

  @override
  String get systemStart => 'Başlat';

  @override
  String get systemStop => 'Durdur';

  @override
  String get systemDone => 'Tamam';

  @override
  String systemShowAll(int count) {
    return 'Tümünü göster ($count)';
  }

  @override
  String get agentUnreachable =>
      'Ajana ulaşılamıyor (PC açık ve Tailscale bağlı mı?)';

  @override
  String get agentTls => 'Güvenli bağlantı kurulamadı';

  @override
  String get agentBadToken => 'Ajan bu telefonu reddetti; yeniden eşle';

  @override
  String get agentWrongTailnetUser =>
      'Bu Tailscale hesabına ajanda izin verilmiyor';

  @override
  String get agentPermissionDenied =>
      'İzin yok (sistem servisleri root yetkisi ister)';

  @override
  String get agentFeatureOff => 'Bu özellik ajanda kapalı';

  @override
  String get pairScanTitle => 'Ajanla eşle';

  @override
  String get pairScanHint =>
      'Sunucuda tiphys-agent pair --name \"Telefon\" çalıştır ve QR kodu okut';

  @override
  String get pairNotTiphys => 'Bu bir Tiphys eşleşme kodu değil';

  @override
  String get pairWithQr => 'QR kodla eşle';

  @override
  String get agentSettings => 'Ajan ayarları';

  @override
  String get agentFeatures => 'Özellikler';

  @override
  String get agentRestartHint =>
      'Özellik değişiklikleri ajan yeniden başlayınca uygulanır.';

  @override
  String get agentRestartRequired =>
      'Kaydedildi. Özellik değişiklikleri için ajanı yeniden başlat.';

  @override
  String get agentAllowedRoots => 'İzin verilen klasörler';

  @override
  String get agentAllowedRootsHint =>
      'Her satıra bir tane. Claude ve dosya işlemleri bunların dışına çıkmaz.';

  @override
  String get agentDevices => 'Eşleşmiş cihazlar';

  @override
  String get agentRevoke => 'İptal et';

  @override
  String agentRevokeConfirm(String name) {
    return '$name cihazının erişimi iptal edilsin mi?';
  }

  @override
  String get agentLockAll => 'Her şeyi kilitle';

  @override
  String get agentLockAllHint =>
      'Bu telefon dahil tüm eşleşmiş cihazları iptal eder. Tekrar girmek için sunucuda yeniden eşle.';

  @override
  String get agentLockAllConfirm =>
      'Bu telefon dahil ajandaki tüm cihazlar iptal edilsin mi?';

  @override
  String get agentFeatSystem => 'Sistem metrikleri';

  @override
  String get agentFeatServices => 'systemd servisleri';

  @override
  String get agentFeatWatch => 'Host izleme (çevrimdışı uyarısı)';

  @override
  String get claudeLive => 'Açık oturumlar';

  @override
  String get claudeHistory => 'Geçmiş';

  @override
  String get claudeContinue => 'Devam et';

  @override
  String get claudeStart => 'Başlat';

  @override
  String get claudeFolder => 'Klasör';

  @override
  String get claudeChooseFolder => 'Seç';

  @override
  String get claudePromptHint => 'Claude ne yapsın?';

  @override
  String get claudeQueueHint => 'Sıraya mesaj ekle…';

  @override
  String get claudeModeBypassShort => 'İzin sorma';

  @override
  String get claudeModeAcceptShort => 'Düzenlemeleri kabul et';

  @override
  String get claudeModeDefaultShort => 'Sor';

  @override
  String get claudeStatusRunning => 'çalışıyor';

  @override
  String get claudeStatusWaiting => 'seni bekliyor';

  @override
  String get claudeStatusIdle => 'bitti';

  @override
  String get claudeStatusError => 'hata';

  @override
  String get claudeStatusStopped => 'kapandı';

  @override
  String get claudeThinking => 'Düşünme';

  @override
  String claudePermissionTitle(String tool) {
    return 'Claude $tool kullanmak istiyor';
  }

  @override
  String get claudeAllow => 'İzin ver';

  @override
  String get claudeDeny => 'Reddet';

  @override
  String get claudeAllowed => 'İzin verildi';

  @override
  String get claudeDenied => 'Reddedildi';

  @override
  String claudeResultLine(int turns, int seconds) {
    return '$turns tur · $seconds sn';
  }

  @override
  String get claudeWorking => 'Claude çalışıyor…';

  @override
  String get claudeSlashCommands => 'Slash komutları';

  @override
  String get claudeStop => 'Durdur';

  @override
  String get claudeSend => 'Gönder';

  @override
  String get claudeEndSession => 'Oturumu kapat';

  @override
  String get integrationAuthFailed => 'Giriş reddedildi (token\'ı kontrol et)';

  @override
  String get siteUp => 'Açık';

  @override
  String get siteDown => 'Kapalı';

  @override
  String get siteMaintenance => 'Bakımda';

  @override
  String get sitePaused => 'Duraklatıldı';

  @override
  String get sitePending => 'Bekliyor';

  @override
  String sitesAllUp(int count) {
    return '$count sitenin hepsi açık';
  }

  @override
  String sitesSomeDown(int count) {
    return '$count site kapalı';
  }

  @override
  String get siteAdd => 'Site ekle';

  @override
  String siteDeleteConfirm(String name) {
    return '$name izlemeden çıkarılsın mı? Geçmişi de silinir.';
  }

  @override
  String get sitePause => 'Duraklat';

  @override
  String get siteResume => 'Devam ettir';

  @override
  String get sitePing => 'Yanıt';

  @override
  String get sitePingChart => 'Yanıt süresi grafiği';

  @override
  String get siteIncidents => 'Kesintiler ve düzelmeler';

  @override
  String get siteNoIncidents => 'Kayıtlı kesinti yok';

  @override
  String get siteType => 'Kontrol türü';

  @override
  String get siteKeyword => 'Anahtar kelime';

  @override
  String get siteNotifyNote =>
      'Kesinti ve düzelme uyarıları ntfy üzerinden telefonuna gelir (konu: siteler).';

  @override
  String get daysShort => 'g';

  @override
  String get hoursShort => 'sa';

  @override
  String get dozzlePause => 'Duraklat';

  @override
  String get dozzleResume => 'Devam';

  @override
  String dozzleBuffered(int count) {
    return '$count yeni satır bekliyor';
  }

  @override
  String get dozzleNoLogs => 'Log satırı yok';

  @override
  String get homepageOpenReal => 'Homepage\'i tarayıcıda aç';

  @override
  String homepageDown(String names) {
    return 'Yanıt vermiyor: $names';
  }

  @override
  String get grafanaAll => 'Hepsi';

  @override
  String grafanaOpenPanel(String type) {
    return '$type paneli: tarayıcıda aç';
  }

  @override
  String get dozzleRunning => 'çalışıyor';

  @override
  String get dozzleStopped => 'durmuş ya da sorunlu';

  @override
  String get notifClaudeDoneTitle => 'Claude bitirdi';

  @override
  String get notifClaudeWaitingTitle => 'Claude onayını bekliyor';

  @override
  String notifClaudeWaitingBody(String title, String tool) {
    return '$title · $tool kullanmak istiyor';
  }

  @override
  String get notifClaudeErrorTitle => 'Claude hatayla durdu';

  @override
  String notifHostOfflineTitle(String host) {
    return '$host çevrimdışı';
  }

  @override
  String notifHostOfflineBody(int minutes) {
    return '$minutes dakikadır yanıt yok';
  }

  @override
  String notifHostOnlineTitle(String host) {
    return '$host tekrar çevrimiçi';
  }

  @override
  String get notifTestTitle => 'Tiphys test bildirimi';

  @override
  String get pushThisPhone => 'Bu telefon';

  @override
  String get pushEnable => 'Bildirimleri aç';

  @override
  String get pushEnabled => 'Bildirimler açık';

  @override
  String get pushNoDistributor =>
      'Önce ntfy uygulamasını kur, varsayılan sunucusunu kendi ntfy sunucun (ör. :2586) yapıp giriş yap. Tiphys bildirimleri onun üzerinden, Google\'sız alır.';

  @override
  String get pushChooseDistributor => 'Şunun üzerinden al';

  @override
  String pushRegistered(String hosts) {
    return 'Kayıtlı ajanlar: $hosts';
  }

  @override
  String get pushSendTest => 'Test bildirimi gönder';

  @override
  String get pushDisable => 'Kapat';

  @override
  String get pushSitesTopic =>
      'Site uyarıları (Uptime Kuma) doğrudan ntfy uygulamasına gelir: orada siteler konusuna abone ol.';

  @override
  String get pushOpenNtfy => 'ntfy\'de abone ol';

  @override
  String get grafanaNoAlerts => 'Aktif alarm yok';

  @override
  String get grafanaFiring => 'Tetiklendi';

  @override
  String get grafanaPending => 'Bekliyor';

  @override
  String get grafanaNoData => 'Veri yok';

  @override
  String get grafanaNormal => 'Normal';

  @override
  String get agentPathNotAllowed => 'Bu klasör ajanın izinli kökleri dışında';

  @override
  String get auditEmpty => 'Henüz kayıtlı işlem yok';

  @override
  String get claudeAttachImage => 'Fotoğraf ekle';

  @override
  String get claudeRemoveImage => 'Fotoğrafı kaldır';

  @override
  String claudeUsageSemantics(String usage) {
    return 'Kullanım: $usage';
  }

  @override
  String get clipboardCopiedPhone => 'Telefon panosuna kopyalandı';

  @override
  String get clipboardCopyPhone => 'Telefona kopyala';

  @override
  String get clipboardFromPc => 'PC\'den al';

  @override
  String get clipboardPastePhone => 'Telefondan yapıştır';

  @override
  String get clipboardPcContent => 'PC panosu';

  @override
  String get clipboardSent => 'PC panosuna gönderildi';

  @override
  String get clipboardToPc => 'PC\'ye gönder';

  @override
  String get commonCreate => 'Oluştur';

  @override
  String get commonNothingFound => 'Sonuç yok';

  @override
  String durationHours(int n) {
    return '$n sa';
  }

  @override
  String durationMinutes(int n) {
    return '$n dk';
  }

  @override
  String get editorChangedOnDisk =>
      'Dosya siz açtıktan sonra bilgisayarda değişmiş. Sizin sürümünüzle üzerine yazılsın mı?';

  @override
  String get editorDiscard => 'Vazgeç';

  @override
  String get editorDiscardChanges => 'Kaydedilmemiş değişiklikler silinsin mi?';

  @override
  String get editorNotText =>
      'Bu dosya metin değil (ya da 1 MB\'tan büyük); burada düzenlenemez.';

  @override
  String get editorOverwrite => 'Üzerine yaz';

  @override
  String get editorSaved => 'Kaydedildi';

  @override
  String get editorWrap => 'Satırları kaydır';

  @override
  String get filesEdit => 'Düzenle';

  @override
  String get gitBranches => 'Dallar';

  @override
  String gitChanges(int n) {
    return 'Değişiklikler ($n)';
  }

  @override
  String get gitClean => 'Değişiklik yok, çalışma alanı temiz';

  @override
  String get gitCommitAll => 'Tüm değişiklikleri commit\'le';

  @override
  String get gitCommitMessage => 'Commit mesajı';

  @override
  String gitCommitStaged(int n) {
    return 'Hazırlanan $n dosyayı commit\'le';
  }

  @override
  String get gitCommitted => 'Commit edildi';

  @override
  String get gitDetached => '(bağımsız HEAD)';

  @override
  String get gitDiffTruncated =>
      'Diff çok uzun; yalnızca ilk 512 KB gösteriliyor.';

  @override
  String get gitDiscard => 'Değişiklikleri geri al';

  @override
  String gitDiscardConfirm(String file) {
    return '$file dosyasındaki tüm değişiklikler geri alınsın mı? Bu geri alınamaz.';
  }

  @override
  String get gitFetch => 'Fetch';

  @override
  String get gitHistory => 'Geçmiş';

  @override
  String get gitMessageRequired => 'Commit mesajı yazın';

  @override
  String get gitNewBranch => 'Yeni dal';

  @override
  String get gitNoCommits => 'Henüz commit yok';

  @override
  String get gitNoDiff => 'Fark yok';

  @override
  String get gitNothingToCommit => 'Commit\'lenecek değişiklik yok';

  @override
  String get gitNotRepo => 'Bu klasör bir Git deposu değil';

  @override
  String get gitPull => 'Pull';

  @override
  String get gitPullFailed => 'Uzak depodan alınamadı';

  @override
  String get gitPush => 'Push';

  @override
  String get gitPushFailed => 'Push başarısız';

  @override
  String get gitRemoteBranches => 'Uzak dallar';

  @override
  String get gitStage => 'Hazırla';

  @override
  String get gitStageAll => 'Tümünü hazırla';

  @override
  String get gitStaged => 'Hazırlanan';

  @override
  String gitSwitched(String branch) {
    return '$branch dalına geçildi';
  }

  @override
  String get gitUnstage => 'Hazırlıktan çıkar';

  @override
  String get gitUnstaged => 'Hazırlanmamış';

  @override
  String get maintenanceActive => 'Bakımda';

  @override
  String get maintenanceAdd => 'Yeni bakım penceresi';

  @override
  String maintenanceDeleteConfirm(String name) {
    return '\"$name\" bakım penceresi silinsin mi?';
  }

  @override
  String get maintenanceDuration => 'Süre (şimdi başlar)';

  @override
  String get maintenanceEmpty => 'Bakım penceresi yok';

  @override
  String get maintenanceEnded => 'Bitti';

  @override
  String get maintenanceExplain =>
      'Bakım penceresi süresince seçili sitelerin kesintisi bildirilmez.';

  @override
  String get maintenanceInactive => 'Pasif';

  @override
  String get maintenanceName => 'Ad';

  @override
  String get maintenanceNeedsSites => 'Bir ad girin ve en az bir site seçin';

  @override
  String get maintenanceScheduled => 'Planlandı';

  @override
  String get maintenanceTitle => 'Bakım pencereleri';

  @override
  String get portsExplain =>
      'Sadece localhost\'u dinleyen portlar tailnet\'e (internete değil) paylaşılıp telefonda açılabilir.';

  @override
  String portsLocalOnly(String address) {
    return 'Sadece yerel ($address)';
  }

  @override
  String portsOpen(String address) {
    return 'Tailnet\'ten erişilebilir ($address)';
  }

  @override
  String get portsShare => 'Paylaş';

  @override
  String portsShareConfirm(int port) {
    return '$port portu HTTPS ile tailnet\'e paylaşılsın mı?';
  }

  @override
  String get portsShared => 'Tailnet\'e paylaşıldı (HTTPS)';

  @override
  String get portsUnshare => 'Paylaşımı durdur';

  @override
  String get processesByCpu => 'İşlemci';

  @override
  String get processesByMemory => 'Bellek';

  @override
  String processesConfirm(String action, String name, int pid) {
    return '$action: $name ($pid)?';
  }

  @override
  String get processesKill => 'Zorla sonlandır';

  @override
  String get processesTerminate => 'Sonlandır';

  @override
  String get quickActionNoOutput => '(çıktı yok)';

  @override
  String get quickActionRun => 'Çalıştır';

  @override
  String quickActionRunConfirm(String name, String host) {
    return '\"$name\" $host üzerinde çalıştırılsın mı?';
  }

  @override
  String get quickActionRunning => 'Çalışıyor…';

  @override
  String get quickActionsTitle => 'Hızlı işlemler';

  @override
  String get siteAddToHomepage => 'Homepage\'e de ekle';

  @override
  String get siteCertExpiry => 'SSL bitiş uyarısı';

  @override
  String get siteCertExpiryHint => 'Sertifika bitmeden önce bildir';

  @override
  String get siteHomepageFailed => 'Site eklendi ama Homepage güncellenemedi';

  @override
  String get siteHomepageGroup => 'Homepage grubu';

  @override
  String get toolsAudit => 'İşlem kaydı';

  @override
  String get toolsClipboard => 'Pano';

  @override
  String get toolsPorts => 'Portlar';

  @override
  String get toolsPortsHint => 'Geliştirme sunucularını telefonda aç';

  @override
  String get toolsProcesses => 'Süreçler';

  @override
  String get toolsScreenshot => 'Ekran görüntüsü';

  @override
  String get toolsScreenshotRetake => 'Yeniden çek';

  @override
  String get toolsTitle => 'Araçlar';

  @override
  String get voiceEmpty => 'Konuşma anlaşılamadı';

  @override
  String get voiceNoPermission => 'Mikrofon izni gerekli';

  @override
  String get voiceRecord => 'Sesli mesaj';

  @override
  String voiceRecording(String time) {
    return 'Kaydediliyor $time';
  }

  @override
  String get voiceStop => 'Durdur ve yazıya çevir';

  @override
  String get voiceTranscribing => 'Yazıya çevriliyor…';

  @override
  String notifDiskFullTitle(String host) {
    return '$host: disk dolmak üzere';
  }

  @override
  String notifDiskFullBody(String mount, int percent) {
    return '$mount %$percent dolu';
  }

  @override
  String notifDiskOkTitle(String host) {
    return '$host: disk alanı tekrar normal';
  }

  @override
  String notifServiceFailedTitle(String host) {
    return '$host: servis çöktü';
  }

  @override
  String notifServiceRecoveredTitle(String host) {
    return '$host: servis düzeldi';
  }

  @override
  String notifGrafanaAlertTitle(String name) {
    return 'Alarm: $name';
  }

  @override
  String notifGrafanaResolvedTitle(String name) {
    return 'Düzeldi: $name';
  }

  @override
  String notifCommandDoneTitle(String host) {
    return '$host: komut bitti';
  }

  @override
  String notifCommandFailedTitle(String host, int code) {
    return '$host: komut hata verdi (çıkış $code)';
  }

  @override
  String notifCommandBody(String command, int seconds) {
    return '$command · $seconds sn';
  }

  @override
  String get agentAlerts => 'Uyarılar (disk, servis, Grafana)';

  @override
  String get agentAlertsDiskPercent => 'Disk dolu eşiği (%)';

  @override
  String get agentAlertsInterval => 'Kontrol aralığı (saniye)';

  @override
  String get agentAlertsFailedServices => 'systemd servisi çökünce bildir';

  @override
  String get agentAlertsGrafana => 'Grafana alarmları';

  @override
  String get agentAlertsDatasources => 'Prometheus veri kaynağı UID\'leri';

  @override
  String get agentAlertsDatasourcesHint =>
      'Virgülle ayırın; Grafana\'nın kendi alarmları her zaman dahil';

  @override
  String get agentAlertsUseProfileGrafana => 'Profildeki Grafana\'yı kullan';

  @override
  String get agentFeatDesktop => 'Masaüstü (pano, ekran görüntüsü)';

  @override
  String get agentFeatTranscribe => 'Sesi yazıya çevirme';

  @override
  String get grafanaAlerts => 'Alarmlar';

  @override
  String get grafanaActiveOnly => 'Etkin';

  @override
  String get grafanaAllRules => 'Tüm kurallar';

  @override
  String grafanaAllNormal(int n) {
    return '$n kuralın hepsi normal';
  }

  @override
  String grafanaActiveAlerts(int active, int total) {
    return '$total kuraldan $active tanesi etkin';
  }

  @override
  String get grafanaAlertsNote =>
      'Bu alarmların telefon bildirimleri ajandan gelir (Ajan ayarları › Uyarılar).';

  @override
  String get dozzleShareLog => 'Log dosyasını paylaş';

  @override
  String get shareTitle => 'Bilgisayara gönder';

  @override
  String shareItems(int n) {
    return '$n öğe';
  }

  @override
  String get shareText => 'Metin';

  @override
  String get shareToHost => 'Bilgisayar';

  @override
  String get shareFolder => 'Klasör';

  @override
  String get shareSend => 'Gönder';

  @override
  String shareSent(int n, String host) {
    return '$n öğe $host hostuna gönderildi';
  }

  @override
  String get claudeWorktree => 'Ayrı git worktree\'de';

  @override
  String get claudeWorktreeHint =>
      'Kardeş klasörde yeni dal; çalışma alanınız değişmez';

  @override
  String get agentNoDisplay =>
      'Bilgisayarda masaüstü oturumu yok (kimse giriş yapmamış mı?)';

  @override
  String get agentPortPublic => 'Bu port zaten tailnet\'ten erişilebilir';

  @override
  String get grafanaExplore => 'Hızlı sorgu';

  @override
  String get grafanaExploreHint => 'Explore gibi PromQL / LogQL';

  @override
  String get grafanaExploreEmpty => 'Bir sorgu yazıp çalıştırın';

  @override
  String get grafanaNoDatasources => 'Prometheus ya da Loki veri kaynağı yok';

  @override
  String get grafanaRun => 'Çalıştır';

  @override
  String filesShowAll(int count) {
    return '$count öğe daha göster';
  }

  @override
  String get ntfyExplain =>
      'Bildirimler bu telefondaki ntfy uygulamasına gelir; sunucuya girişi orada yaparsın (Ayarlar › Kullanıcıları yönet). Aşağıdaki konular \"ntfy\'da aç\" kısayolu olur.';

  @override
  String get scriberrExplain =>
      'Sesli mesajlar PC\'deki Tiphys ajanı üzerinden yazıya çevrilir; Scriberr anahtarı ajanda durur. Burada dili ve modeli seçersin.';

  @override
  String get commonRefresh => 'Yenile';

  @override
  String get claudeInTerminalNote =>
      'Bu oturum PC\'de terminalde açık. Buradan okuyabilir ya da telefona devralabilirsin.';

  @override
  String get claudeTerminalSessions => 'Terminalde açık';

  @override
  String get claudeTerminalSessionsHint =>
      'PC\'de Tiphys dışında çalışan Claude Code oturumları. Burada yalnız okunur.';

  @override
  String get claudePromptOptional => 'İlk mesaj (isteğe bağlı)';

  @override
  String get claudeUntitled => 'Yeni oturum';

  @override
  String get claudeTakeover => 'Telefona devral';

  @override
  String claudeTakeoverConfirm(String id) {
    return 'PC\'deki terminalde açık Claude kapatılır ve bu oturum tüm geçmişiyle burada sürer. Sonra terminalde devam etmek için:\nclaude --resume $id';
  }

  @override
  String get claudeTerminalBusy =>
      'Claude şu an terminalde çalışıyor. Bitince tekrar dene.';

  @override
  String get claudeTerminalGone => 'Bu oturum artık terminalde açık değil.';

  @override
  String get claudeTerminalStuck =>
      'Terminaldeki oturum kapanmadı. PC\'de kapatıp tekrar dene.';

  @override
  String voiceTranscribingProgress(int secs, int estimate) {
    return 'Sunucuda yazıya çevriliyor · $secs sn / ~$estimate sn';
  }

  @override
  String get claudeRestored =>
      'Ajan yeniden başladı · kaldığın yerden devam edebilirsin';

  @override
  String get claudeCompacted => 'Önceki kısım özetlendi';

  @override
  String get claudeSessionGone =>
      'Bu oturum artık yok. Devam etmek için Geçmiş’ten aç.';

  @override
  String get claudeReconnecting => 'Bağlantı koptu, yeniden bağlanılıyor…';

  @override
  String get claudeOutboxWaiting => 'bağlantı bekleniyor';

  @override
  String get claudeOutboxSending => 'gönderiliyor…';

  @override
  String get claudeDecisionFailedTitle => 'Karar gönderilemedi';

  @override
  String get claudeDecisionFailedBody =>
      'İzin isteğini yanıtlamak için Tiphys’i aç.';

  @override
  String get agentSection => 'Ajan';

  @override
  String get agentVersion => 'Sürüm';

  @override
  String agentOutdated(String version) {
    return '$version · güncel değil';
  }

  @override
  String agentOutdatedHint(String version) {
    return 'Bu uygulama $version sürümlü ajan bekliyor. PC\'de tools/deploy-agent.sh ile (uzak sunucu) ya da ajanı yeniden derleyerek (yerel) güncelle.';
  }

  @override
  String get agentUptime => 'Açık kalma süresi';

  @override
  String agentUptimeDays(int days, int hours) {
    return '$days g $hours sa';
  }

  @override
  String agentUptimeHours(int hours, int minutes) {
    return '$hours sa $minutes dk';
  }

  @override
  String agentUptimeMinutes(int minutes) {
    return '$minutes dk';
  }

  @override
  String get agentMemory => 'Bellek';

  @override
  String agentMemoryValue(String agent, String children) {
    return 'ajan $agent · Claude/komutlar $children';
  }

  @override
  String get agentRestarts => 'Beklenmedik yeniden başlama';

  @override
  String notifAgentRestartedTitle(String host) {
    return '$host: ajan beklenmedik şekilde yeniden başladı';
  }

  @override
  String get notifAgentRestartedBody =>
      'Çöktü ya da belleği bitti. Canlı Claude oturumları geri yüklendi.';

  @override
  String get agentRestartsWindow => 'son 24 saat';
}
