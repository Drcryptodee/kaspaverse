import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (P0.5, INV-11): credentials live in android/key.properties —
// gitignored, never committed (gate hygiene fails on a tracked copy). Template:
// android/key.properties.template; founder setup: docs/RELEASE.md.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "org.kaspaverse.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.kaspaverse.app"
        // Min SDK 26: BiometricPrompt baseline; StrongBox detected at runtime in P1 (P0 §0.4).
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // arm64 only in P0: kaspa-hashes (pinned rev 90dbf074) has no
            // x86_64-android asm path — its build script panics "Unsupported
            // OS" — and cargokit otherwise builds every ABI. Widening is a
            // deliberate later call (P0.5 release skeleton at the earliest).
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // EXPLICIT debug fallback, never a silent one: without
            // key.properties, `flutter run --release` still works for perf
            // smoke tests, but the warning below fires and tools/release.sh
            // (the only documented release path) refuses to ship the result —
            // it verifies the actual signer cert on the APK, not this config.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "WARNING: android/key.properties missing — release build will be " +
                        "DEBUG-SIGNED (dev smoke test only, unshippable). See docs/RELEASE.md."
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // P1.2 §0.5, D-034 — the ONE new platform dep this phase. BiometricPrompt
    // (BIOMETRIC_STRONG) gating the Keystore Cipher for Path-A unlock. Stable
    // 1.1.0; dependency-steward audited (INV-7). Keystore itself uses raw
    // `android.security.keystore` (platform, no dep). Rejected: any Flutter
    // biometric/vault plugin (third-party code on the custody path, §0.5).
    implementation("androidx.biometric:biometric:1.1.0")
}
