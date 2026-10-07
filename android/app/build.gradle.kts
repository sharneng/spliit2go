import java.io.ByteArrayOutputStream
import java.util.Properties
import javax.inject.Inject

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Play upload key (#107), from android/key.properties, which is
// gitignored with the keystore itself; see SETUP.md, "Release build
// (Android)". Without the file, dev release builds are signed with the
// debug key, so anyone can still build and run one locally; prod release
// builds refuse to build (#219).
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasUploadKey = !keyProperties.isEmpty

// The commit this build is from, for About (#176): the full hash, with
// "-dirty" when tracked files have uncommitted changes, or "?" when git
// couldn't tell; empty without git. A ValueSource, so git runs on every
// build and both HEAD and the dirty state are inputs Gradle tracks (also
// under the configuration cache). See docs/decisions/build-info.md.
abstract class GitCommitSource : ValueSource<String, GitCommitSource.Params> {
    interface Params : ValueSourceParameters {
        val repoDir: DirectoryProperty
    }

    @get:Inject
    abstract val execOperations: ExecOperations

    private fun git(vararg args: String): Pair<Int, String> {
        val out = ByteArrayOutputStream()
        val result = execOperations.exec {
            commandLine("git", *args)
            workingDir = parameters.repoDir.get().asFile
            standardOutput = out
            errorOutput = ByteArrayOutputStream()
            isIgnoreExitValue = true
        }
        return result.exitValue to out.toString().trim()
    }

    override fun obtain(): String = try {
        val (status, sha) = git("rev-parse", "HEAD")
        if (status != 0 || sha.isEmpty()) {
            ""
        } else {
            when (git("diff", "--quiet", "HEAD", "--").first) {
                0 -> sha
                1 -> "$sha-dirty"
                else -> "$sha?"
            }
        }
    } catch (e: Exception) {
        "" // No git on PATH.
    }
}

val gitCommit: String = providers.of(GitCommitSource::class) {
    parameters.repoDir.set(rootProject.layout.projectDirectory.dir(".."))
}.get()
if (gitCommit.isEmpty() || gitCommit.endsWith("?")) {
    logger.warn("Couldn't read the git commit; About will show it as unknown.")
}

android {
    namespace = "com.sharneng.spliit2go"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.sharneng.spliit2go"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "GIT_COMMIT", "\"$gitCommit\"")
    }

    buildFeatures {
        buildConfig = true
        resValues = true
    }

    // Two apps from one codebase (#219): dev, the default (pubspec.yaml's
    // default-flavor), installs beside prod, the real app for the stores
    // and for APKs given out. See docs/decisions/app-flavors.md.
    flavorDimensions += "app"
    productFlavors {
        create("dev") {
            dimension = "app"
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Spliit2Go Dev")
        }
        create("prod") {
            dimension = "app"
            resValue("string", "app_name", "Spliit2Go")
        }
    }

    signingConfigs {
        if (!keyProperties.isEmpty) {
            create("release") {
                storeFile = rootProject.file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            // Keep rules for ML Kit (#125); see the file.
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

// A prod release goes to people: signed with the upload key, never the
// debug key (#219).
tasks.matching { it.name == "preProdReleaseBuild" }.configureEach {
    doFirst {
        if (!hasUploadKey) {
            throw GradleException(
                "A prod release build needs the upload key in android/key.properties; " +
                    "see SETUP.md, \"Release build (Android)\".")
        }
    }
}

// Only prod goes to Play: a dev bundle could only be uploaded by mistake.
// Checked against the tasks asked for, before anything is built: the
// bundle task itself only runs once the bundle is already written.
if (gradle.startParameter.taskNames.any { it.substringAfterLast(':').startsWith("bundleDev") }) {
    throw GradleException("Play bundles are prod only: add --flavor prod.")
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
    // Receipt scanning on the phone (#125), called from ReceiptScanChannel.kt.
    // Text recognition with the Latin model bundled (about 4 MB), so it
    // works offline from the first use.
    implementation("com.google.mlkit:text-recognition:16.0.1")
    // Chinese and Japanese (#153): Google Play services downloads each model
    // when the user picks it (about 260 KB each in the app, against about
    // 4 MB each bundled).
    implementation("com.google.android.gms:play-services-mlkit-text-recognition-chinese:16.0.1")
    implementation("com.google.android.gms:play-services-mlkit-text-recognition-japanese:16.0.1")
    // The Document Scanner: a small client; Google Play services downloads
    // the scanner itself on first use.
    implementation("com.google.android.gms:play-services-mlkit-document-scanner:16.0.0")
}
