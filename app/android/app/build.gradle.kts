import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: keystore and passwords live outside the project, in ~/.config/tiphys/release/key.properties
// (or TIPHYS_KEY_PROPERTIES). If the file is missing, the build is signed with the debug key and a warning is printed.
val releaseKeyFile = file(System.getenv("TIPHYS_KEY_PROPERTIES") ?: "${System.getProperty("user.home")}/.config/tiphys/release/key.properties")
val releaseKey = Properties().apply { if (releaseKeyFile.exists()) releaseKeyFile.inputStream().use { load(it) } }

android {
    namespace = "com.aurict.tiphys"
    compileSdk = 37 // androidx.core 1.19 and flutter_local_notifications 23 need 37 (Flutter default is 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications requires library desugaring
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

    // The app is built for arm64 only (libflutter/libapp are arm64 only); the armeabi-v7a/x86_64 copies
    // pulled in by plugins (~9 MB) could not run anyway. No emulator is used.
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

// The UnifiedPush connector brings the JVM "tink", flutter_secure_storage brings "tink-android"; the JVM one is
// excluded so the same classes don't arrive twice (tink-android contains the same packages).
configurations.all {
    exclude(group = "com.google.crypto.tink", module = "tink")
}
