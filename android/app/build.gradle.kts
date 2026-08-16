import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (P0.5, INV-11): credentials live in android/key.properties —
// gitignored, never committed (gate hygiene fails on a tracked copy). Template:
// android/key.properties.template — copy it to android/key.properties and
// fill in the keystore path, alias and passwords. Never committed.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

// Side-by-side DEV INSTALL (opt-in, default OFF).
//
// `KV_DEV_INSTALL=1` gives non-release builds a distinct applicationId, so a
// throwaway test wallet installs *beside* the real app instead of replacing it.
// This exists because the create ceremony cannot be walked on a device that
// already holds a vault — `seal_and_persist` refuses to overwrite one (INV-4)
// and there is no delete path — so proving F1 on glass otherwise meant wiping a
// wallet holding real coins, and trusting a written backup to get it back. That
// is precisely the risk F1 is about, so it is not an acceptable way to test F1.
//
// **Opt-in, not a new default**, and the default is the whole point: every
// existing script, skill and habit (`tools/release.sh`, `tools/perf/*.sh`, the
// android-device skill, plain `flutter build apk --profile`) keeps producing
// `org.kaspaverse.app` with no flag and no edit. An always-on suffix would have
// silently pointed the perf harness at a stale package.
//
// The guard is `name != "release"`, so release can never take a suffix by
// construction rather than by comment — the applicationId is the published
// app's identity, and publication is founder-owned (D-094).
val devInstall = System.getenv("KV_DEV_INSTALL") == "1"

android {
    // NOT the applicationId: `namespace` is the Kotlin/JNI package, and it is
    // deliberately left alone. The JNI seed lane resolves classes by
    // `org/kaspaverse/app/...` and the two MethodChannels are literal strings
    // shared with Dart — all of which would break if the suffix moved this.
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
        // The manifest's label is a placeholder so the dev install can be told
        // apart on the launcher. Default is the shipped name, byte for byte.
        manifestPlaceholders["appLabel"] = "KaspaVerse"
        // Min SDK 26: BiometricPrompt baseline; StrongBox detected at runtime in P1 (P0 §0.4).
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // arm64 only in P0: kaspa-hashes (pin `cfafeb4c` v2.0.1 — D-058;
            // constraint verified durable on upstream master, D-023f) has no
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
                        "DEBUG-SIGNED (dev smoke test only, unshippable) — android/key.properties was not found."
                )
                signingConfigs.getByName("debug")
            }
        }
    }

    // `configureEach`, not `getByName("profile")`: the profile build type is
    // created by the Flutter Gradle plugin, and this applies to it whenever it
    // appears rather than depending on evaluation order. Release is excluded
    // here, and that exclusion is the safety property — not a convention.
    buildTypes.configureEach {
        if (devInstall && name != "release") {
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appLabel"] = "KaspaVerse dev"
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
