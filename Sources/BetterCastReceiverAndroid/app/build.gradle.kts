import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    namespace = "com.bettercast.receiver"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.bettercast.receiver"
        minSdk = 26
        targetSdk = 34
        versionCode = 4
        versionName = "1.3"
    }

    // Release signing. Credentials come from keystore.properties (gitignored) or,
    // failing that, environment variables — never from this file.
    val keystorePropsFile = rootProject.file("keystore.properties")
    val keystoreProps = Properties().apply {
        if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { stream -> load(stream) }
    }
    val storePath = keystoreProps.getProperty("storeFile") ?: System.getenv("BC_KEYSTORE")
    val hasSigning = storePath != null && file(storePath).exists()

    signingConfigs {
        if (hasSigning) {
            create("release") {
                storeFile = file(storePath!!)
                storePassword = keystoreProps.getProperty("storePassword") ?: System.getenv("BC_KEYSTORE_PASSWORD")
                keyAlias = keystoreProps.getProperty("keyAlias") ?: System.getenv("BC_KEY_ALIAS") ?: "bettercast"
                keyPassword = keystoreProps.getProperty("keyPassword") ?: System.getenv("BC_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (hasSigning) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    buildFeatures {
        compose = true
        // Settings shows the version/build, read from BuildConfig.
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.2")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    // Pulled in transitively by material3, but named here because the receiver's
    // settings menu depends on it directly.
    implementation("androidx.compose.material:material-icons-core")
    // The extended set covers the glyphs the UI actually needs (Usb, Wifi, QrCode,
    // Cast...) which the core set does not. It is large, but R8 strips the unused
    // vectors — worth checking the release APK size if minification is ever turned off.
    implementation("androidx.compose.material:material-icons-extended")

    // QR encoding for hotspot credentials — the Mac reads this with its camera,
    // because startLocalOnlyHotspot generates the SSID/passphrase and regenerates
    // them each start, so they can only travel phone -> Mac.
    implementation("com.google.zxing:core:3.5.3")

    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
