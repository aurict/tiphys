import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release imzası: anahtar deposu ve parolaları proje dışında, ~/.config/tiphys/release/key.properties
// (ya da TIPHYS_KEY_PROPERTIES). Dosya yoksa debug anahtarıyla imzalanır ve uyarı basılır.
val releaseKeyFile = file(System.getenv("TIPHYS_KEY_PROPERTIES") ?: "${System.getProperty("user.home")}/.config/tiphys/release/key.properties")
val releaseKey = Properties().apply { if (releaseKeyFile.exists()) releaseKeyFile.inputStream().use { load(it) } }

android {
    namespace = "com.aurict.tiphys"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications kütüphane desugaring ister
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.aurict.tiphys"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeyFile.exists()) {
            create("release") {
                storeFile = file(releaseKey.getProperty("storeFile"))
                storePassword = releaseKey.getProperty("storePassword")
                keyAlias = releaseKey.getProperty("keyAlias")
                keyPassword = releaseKey.getProperty("keyPassword")
            }
        }
    }

    // Uygulama yalnız arm64 için derleniyor (libflutter/libapp sadece arm64); eklentilerin getirdiği
    // armeabi-v7a/x86_64 kopyaları (~9 MB) zaten çalışamaz. Emülatör kullanılmıyor.
    packaging {
        jniLibs {
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86_64/**", "lib/x86/**")
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseKeyFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("Tiphys: release anahtarı yok ($releaseKeyFile), debug anahtarıyla imzalanıyor")
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// UnifiedPush bağlayıcısı JVM sürümü "tink"i, flutter_secure_storage "tink-android"i getiriyor; aynı sınıflar
// iki kez gelmesin diye JVM sürümü çıkarılır (tink-android aynı paketleri içerir).
configurations.all {
    exclude(group = "com.google.crypto.tink", module = "tink")
}
