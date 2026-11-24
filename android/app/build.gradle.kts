import java.util.Properties
import java.util.zip.ZipFile

// Release signing lives outside the repo; see android/key.properties.
// A clone without it still builds (debug-signed), so CI and contributors are not
// blocked on a key they do not have.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

// The ABIs this app is meant to ship. Not expressed as ndk.abiFilters: that setting
// cannot coexist with the per-ABI splits a release build uses, and Gradle refuses the
// whole build if both are present. verifyCoreAbis() enforces the same guarantee and
// enforces it better -- it fails with the missing ABI named, rather than quietly
// producing an APK without a core in it.
val shippedAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")

/**
 * Fails the build when libcores.aar is missing an ABI the app declares.
 *
 * Without this the mismatch is silent and only surfaces on a user's phone: the APK
 * advertises an ABI, Android picks it, and System.loadLibrary finds no core. The
 * tunnel then cannot start at all, with nothing in the UI to explain why. It is an
 * easy state to reach -- one `ABIS=android/arm64 ./scripts/build-cores.sh` for a
 * quick test overwrites the full artifact.
 */
fun verifyCoreAbis() {
    val aar = file("libs/libcores.aar")
    if (!aar.exists()) {
        throw GradleException(
            "android/app/libs/libcores.aar is missing. Build it first:\n" +
                "    ./scripts/build-cores.sh",
        )
    }
    val present = ZipFile(aar).use { zip ->
        zip.entries().asSequence()
            .mapNotNull { Regex("^jni/([^/]+)/").find(it.name)?.groupValues?.get(1) }
            .toSet()
    }
    val missing = shippedAbis - present
    if (missing.isNotEmpty()) {
        throw GradleException(
            "libcores.aar has no native core for: ${missing.joinToString(", ")}\n" +
                "  present: ${present.sorted().joinToString(", ")}\n" +
                "  An APK for a missing ABI would install and then fail to start the " +
                "tunnel, with no visible reason.\n" +
                "  Rebuild all of them:\n" +
                "    ./scripts/build-cores.sh",
        )
    }
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.lupangoding.trefoil"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Application ID is final; changing it after publish breaks upgrades.
        applicationId = "com.lupangoding.trefoil"
        // minSdk is pinned rather than inherited: VpnService per-app allow/disallow
        // rules and the foregroundServiceType we declare both require API 24+.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
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
            // Debug-signed only as a fallback: such a build installs and runs, but
            // must never be published, since the debug key is not yours alone.
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Robolectric supplies the real android.util.Base64 and a working filesystem, so
    // the native state worth testing -- backup encryption, the per-server totals, what
    // is on disk after a crash -- can be tested off a device. The alternative was reshaping
    // security-critical production code to suit a test, which is the worse trade.
    //
    // Note that any Gradle task here needs libs/libcores.aar, which is not in the
    // repo: verifyCoreAbis() fails the build without it. That is why these run in their
    // own CI workflow, after the cores are built, rather than on every push.
    testOptions {
        // Android resources are deliberately not merged into the unit-test classpath.
        // Nothing under test reads one, and turning it on makes AGP package the
        // assets directory that Flutter's own copyFlutterAssets task writes, which
        // Gradle then rejects as two tasks racing for one output.
        unitTests {
            isReturnDefaultValues = true
        }
    }

    packaging {
        jniLibs {
            // Compressed in the APK and extracted at install. Stored, the cores alone
            // made the download 106 MB; compressed it is about a third of that, which is
            // what every in-app update costs. The price is the extracted copy on disk,
            // paid once at install. They are already stripped (-s -w) by build-cores.sh.
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Built from source by scripts/build-cores.sh — not available on any Maven repo.
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("androidx.core:core-ktx:1.15.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16")
}

flutter {
    source = "../.."
}

// Checked once per build rather than per variant: the .aar is a static input, and a
// failure here should stop things before any compilation happens.
verifyCoreAbis()
