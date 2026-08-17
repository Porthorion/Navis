plugins {
    id("com.android.application")
}

android {
    namespace = "com.navis.app.autotestclient"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.navis.app.autotestclient"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
}

dependencies {
    implementation("androidx.media:media:1.7.0")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
