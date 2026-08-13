plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "app.belople.belople_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications uses java.time, which minSdk 24 doesn't
        // have natively; desugaring backports it. Without this the build fails
        // outright at checkDebugAarMetadata.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.belople.belople_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ffmpeg-kit (min_gpl) requires API 24+; take the higher of that and
        // whatever Flutter's default would be.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// rtmp_broadcaster (the Live RTMP publisher) still lists
// `com.android.support:support-v4:28.0.0` — the PRE-AndroidX support library —
// in its build.gradle. Its own code never touches it: every import is androidx
// (ActivityCompat, ContextCompat, annotation), and support-v4 is dead weight
// left behind when the plugin was migrated. Gradle still resolves it though,
// and then the manifest merger dies on
//
//   Namespace 'androidx.versionedparcelable' is used in multiple modules
//
// because the old library and its AndroidX replacement declare the same one.
// Dropping the whole obsolete group is the fix; nothing in the app or in any
// plugin compiles against it.
configurations.all {
    exclude(group = "com.android.support")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
