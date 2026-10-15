import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val appDefines = (project.findProperty("dart-defines") as? String ?: "")
    .split(',').filter { it.isNotEmpty() }.associate {
        val pair = String(Base64.getDecoder().decode(it), Charsets.UTF_8).split('=', limit = 2)
        pair[0] to pair.getOrElse(1) { "" }
    }
val pilotBuild = appDefines["APP_EDITION"] == "pilot"
val signingProperties = Properties()
val signingPath = System.getenv("AIHAPTICS_SIGNING_PROPERTIES")
if (!signingPath.isNullOrBlank()) {
    file(signingPath).inputStream().use { signingProperties.load(it) }
}
val signingReady = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !signingProperties.getProperty(it).isNullOrBlank() } &&
    file(signingProperties.getProperty("storeFile", "__missing__")).isFile
val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (!pilotBuild && releaseRequested && !signingReady) {
    throw GradleException("Public release requires external signing. Run scripts/init-release-signing.ps1; see docs/building.md.")
}

android {
    namespace = "dev.aihaptics.haptics_lab"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.aihaptics.haptics_lab"
        if (!pilotBuild) { applicationIdSuffix = ".community" }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        // Match the Flutter and Rust targets; dependencies may bundle extra ABIs.
        ndk {
            abiFilters += setOf("arm64-v8a", "x86_64")
        }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (signingReady) {
            create("publicRelease") {
                storeFile = file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release {
            // Preserve existing pilot upgrades. Public releases never use debug keys.
            signingConfig = if (pilotBuild) signingConfigs.getByName("debug")
                else if (signingReady) signingConfigs.getByName("publicRelease") else null
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
    testImplementation("junit:junit:4.12")
}
