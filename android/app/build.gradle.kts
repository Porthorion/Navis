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

val allowDebugSignedRelease = System.getenv("NAVIS_ALLOW_DEBUG_SIGNED_RELEASE") == "1"
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.substringAfterLast(':').contains("release", ignoreCase = true)
}

fun requireReleaseSigning() {
    if (!keyPropertiesFile.exists() && !allowDebugSignedRelease) {
        throw GradleException(
            "android/key.properties is required for release builds. " +
                "Set NAVIS_ALLOW_DEBUG_SIGNED_RELEASE=1 only for local development.",
        )
    }
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
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
        resValues = true
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
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    flavorDimensions += "distribution"
    productFlavors {
        if (selfUpdateEnabled) {
            create("sideload") {
                dimension = "distribution"
                buildConfigField("boolean", "SELF_UPDATE_ENABLED", "true")
            }
        } else {
            create("play") {
                dimension = "distribution"
                buildConfigField("boolean", "SELF_UPDATE_ENABLED", "false")
            }
        }
    }

    testOptions {
        // The repeat fixture records posts itself while allowing the caller's tail to run.
        unitTests.isReturnDefaultValues = true
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
        getByName("profile") {
            // Flutter profile builds are used for authenticated, app-owned
            // mobile diagnostics. Preserve the sidecar identity here as well
            // as debug/release so they can never target a user's stable app.
            if (sidecarAppIdSuffix.isNotEmpty()) {
                applicationIdSuffix = sidecarAppIdSuffix
                versionNameSuffix = "-sidecar"
            }
            resValue("string", "app_name", sidecarAppName)
            signingConfig = if (keyPropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
        release {
            if (releaseTaskRequested) requireReleaseSigning()
            if (sidecarAppIdSuffix.isNotEmpty()) {
                applicationIdSuffix = sidecarAppIdSuffix
                versionNameSuffix = "-sidecar"
            }
            resValue("string", "app_name", sidecarAppName)
            signingConfig = if (keyPropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug") // explicit local-development opt-in
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

// Aggregate tasks such as assemble/build can select release variants without
// naming them on the command line. Validate before any selected task executes.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("release", ignoreCase = true) }) {
        requireReleaseSigning()
    }
}

flutter {
    source = "../.."
}

dependencies {
    val workManagerVersion = "2.12.0"
    implementation("androidx.media:media:1.8.0")
    implementation("androidx.work:work-runtime-ktx:$workManagerVersion")
    implementation("androidx.concurrent:concurrent-futures-ktx:1.3.0")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("com.google.guava:guava:33.7.1-android")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.work:work-testing:$workManagerVersion")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.work:work-testing:$workManagerVersion")
}
