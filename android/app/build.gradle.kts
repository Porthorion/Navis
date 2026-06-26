import java.util.Properties

plugins {
    id("com.android.application")

    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load keystore properties if the file exists (git-ignored; never commit secrets).
// Copy android/key.properties.example -> android/key.properties and fill in values.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties()
if (keyPropertiesFile.exists()) {
    keyProperties.load(keyPropertiesFile.inputStream())
}

val sidecarAppIdSuffix =
    System.getenv("NAVIS_APP_ID_SUFFIX")
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: ""
val sidecarAppName =
    System.getenv("NAVIS_APP_NAME")
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: "Navis"
val selfUpdateEnabled =
    System.getenv("NAVIS_SELF_UPDATE")?.trim()?.equals("false", ignoreCase = true) != true

android {
    namespace = "com.navis.app.navis"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    signingConfigs {
        if (keyPropertiesFile.exists()) {
            create("release") {
                keyAlias = keyProperties["keyAlias"] as String?
                keyPassword = keyProperties["keyPassword"] as String?
                storeFile = keyProperties["storeFile"]?.let { file(it as String) }
                storePassword = keyProperties["storePassword"] as String?
            }
        }
    }

    defaultConfig {
        applicationId = "com.navis.app.navis"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("boolean", "SELF_UPDATE_ENABLED", selfUpdateEnabled.toString())
    }

    sourceSets {
        getByName("main") {
            if (selfUpdateEnabled) {
                manifest.srcDir("src/selfupdate")
            }
        }
    }

    buildTypes {
        debug {
            // Optional debug-only sidecar install path for device testing.
            // Example:
            //   NAVIS_APP_ID_SUFFIX=.sidecar NAVIS_APP_NAME="Navis Sidecar" flutter run
            if (sidecarAppIdSuffix.isNotEmpty()) {
                applicationIdSuffix = sidecarAppIdSuffix
                versionNameSuffix = "-sidecar"
            }
            resValue("string", "app_name", sidecarAppName)
            // Keep debug builds updatable from release installs when local
            // release signing is configured (useful for internal dogfooding).
            signingConfig = if (keyPropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
        release {
            if (sidecarAppIdSuffix.isNotEmpty()) {
                applicationIdSuffix = sidecarAppIdSuffix
                versionNameSuffix = "-sidecar"
            }
            resValue("string", "app_name", sidecarAppName)
            signingConfig = if (keyPropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug") // fallback for local dev builds
            // R8 shrinking reduces APK size by ~30–40%.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
