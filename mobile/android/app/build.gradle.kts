import java.util.Properties

val keystoreProperties = Properties().apply {
    rootProject.file("keystore.properties").inputStream().use(::load)
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android { namespace = "com.dots.herness.mobile"; compileSdk = 36
    signingConfigs {
        create("hernessRelease") {
            storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
        }
    }
    defaultConfig {
        applicationId = "com.dots.herness"; minSdk = 26; targetSdk = 35; versionCode = 1; versionName = "0.1.0"
        manifestPlaceholders["hernessGithubClientId"] = providers.gradleProperty("hernessGithubClientId").orNull ?: ""
        externalNativeBuild { cmake { arguments += "-DHERNESS_LIBGIT2_ROOT=${providers.gradleProperty("hernessLibgit2Root").orNull ?: ""}" } }
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }
    buildTypes { release { signingConfig = signingConfigs.getByName("hernessRelease") } }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.07.00"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    // Sandboxed JS for `runtime: js` plugins; Rhino runs interpreted, so tool
    // calls stay synchronous instead of bouncing through a WebView callback.
    implementation("org.mozilla:rhino:1.7.15")
    // Background loops; WorkManager is the only scheduler Android will honour
    // once the app is not in front.
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    testImplementation("junit:junit:4.13.2")
}
