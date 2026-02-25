# Navis ProGuard / R8 rules
#
# Flutter adds its own rules automatically via the Flutter Gradle plugin.
# These rules handle app-specific libraries that need additional preservation.

# ── Kotlin ────────────────────────────────────────────────────────────────────
-keep class kotlin.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn kotlin.**
-keepclassmembers class **$WhenMappings { <fields>; }
-keepclassmembers class kotlin.Metadata {
    public <methods>;
}

# ── Kotlinx Serialization / Coroutines ────────────────────────────────────────
-keepclassmembers class kotlinx.** { *; }
-dontwarn kotlinx.**

# ── audio_service / just_audio ────────────────────────────────────────────────
-keep class com.ryanheise.** { *; }
-dontwarn com.ryanheise.**

# ── flutter_secure_storage ────────────────────────────────────────────────────
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# ── SQLite / SQFlite / Drift ──────────────────────────────────────────────────
-keep class org.sqlite.** { *; }
-keep class org.sqlite.database.** { *; }

# ── OkHttp / Dio (used internally by packages) ────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ── Keep app entry points ──────────────────────────────────────────────────────
-keep class com.navis.app.navis.** { *; }
