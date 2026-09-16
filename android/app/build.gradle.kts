import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Compose 编译器插件（Kotlin 2.x 内置，版本随 Kotlin）
    id("org.jetbrains.kotlin.plugin.compose")
}

val keystoreProperties = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) {
        load(FileInputStream(f))
    }
}

android {
    namespace = "com.md3music.md3music"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    defaultConfig {
        // vivo 原子能 / 原子随身听：实测 com.salt.music 稳定（歌词+不卡机）；
        // com.apple.android.music 会进 Apple Music 专用 SystemUI 路径，易卡顿且状态栏显示 Apple Music。
        // 合作认证仍靠 manifest meta-data token，不依赖伪装包名。
        applicationId = "com.salt.music"
        minSdk = flutter.minSdkVersion
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // USB：只编真机常用 ABI，去掉模拟器 x86 可减小 so 体积
        externalNativeBuild {
            cmake {
                abiFilters("arm64-v8a", "armeabi-v7a")
            }
        }
    }

    // skia / impeller 双渲染：Flutter 3.x 只认 manifest 静态 EnableImpeller。
    flavorDimensions += "renderer"
    productFlavors {
        create("skia") {
            dimension = "renderer"
            manifestPlaceholders["enableImpeller"] = "false"
        }
        create("impeller") {
            dimension = "renderer"
            manifestPlaceholders["enableImpeller"] = "true"
        }
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.isNotEmpty()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                val storeType = keystoreProperties.getProperty("storeType")
                if (!storeType.isNullOrBlank()) {
                    this.storeType = storeType
                }
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Release 必须用持久签名；缺 keystore 时不要静默退回 debug（否则每台 CI 签名不同，无法覆盖安装）
            check(keystoreProperties.isNotEmpty()) {
                "Missing android/keystore.properties — CI must download release.keystore and write secrets."
            }
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            // Disable symbol stripping for Gradle 9.x compatibility
            ndk {
                debugSymbolLevel = "none"
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildFeatures {
        // MiuixDiscoverActivity 使用 Compose + miuix 组件
        compose = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.media:media:1.6.0")
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("io.github.proify.lyricon:provider:0.1.70")
    implementation("io.github.proify.lyricon.lyric:model:0.1.70")
    // SuperLyricApi：基于 Binder 的系统级实时歌词 API（jnitpack，settings.gradle.kts 已声明）
    implementation("com.github.HChenX:SuperLyricApi:3.4")
    // JAudioTagger 社区分叉（支持 MP3/FLAC/Ogg/M4A 等格式的 ID3v2 / VorbisComment 标签读写，
    // 用于在下载完成后向音频文件嵌入标题/艺术家/专辑/封面/歌词）。
    // JitPack 上 AdrienPoupa 分叉仅有 2.2.3（无 2.2.5）。
    implementation("com.github.AdrienPoupa:jaudiotagger:2.2.3")
    // 方案B阶段1：app 侧 Kotlin 引用 androidx.media3.common 类型（UnstableApi、Player 等）。
    // media3-common 为单一 maven 源（fork 同版本 1.4.1），此处显式依赖以便编译期可见
    // （fork 用 implementation 隐藏了传递依赖）。session/exoplayer 仍是 fork 本地源码，勿加 maven。
    implementation("androidx.media3:media3-common:1.4.1")

    // ==================== Miuix 风格测试页（原生 Compose） ====================
    // miuix-android 0.8.8：Kotlin 2.3.20 + Compose Foundation 1.10.3 编译，
    // minCompileSdk=36，与当前工程（compileSdk 36 / Kotlin 2.3.20）完全匹配
    implementation("top.yukonga.miuix.kmp:miuix-android:0.8.8")
    // Compose 宿主（ComposeView）+ 图片加载（Coil）
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("io.coil-kt:coil-compose:2.7.0")
}

// MD3Music fork: 全局强制 media3 版本与本地 just_audio fork 的 exoplayer 源码一致（1.4.1）。
// video_player 等库声明更高版本（1.9.2），若不强制会出现重复类（本地源码 vs maven 1.9.2）。
// media3-exoplayer 的 maven 版本全局排除——由 just_audio fork 内的本地源码提供。
configurations.all {
    exclude(group = "androidx.media3", module = "media3-exoplayer")
    resolutionStrategy {
        force(
            "androidx.media3:media3-common:1.4.1",
            "androidx.media3:media3-container:1.4.1",
            "androidx.media3:media3-database:1.4.1",
            "androidx.media3:media3-datasource:1.4.1",
            "androidx.media3:media3-decoder:1.4.1",
            "androidx.media3:media3-exoplayer-dash:1.4.1",
            "androidx.media3:media3-exoplayer-hls:1.4.1",
            "androidx.media3:media3-exoplayer-rtsp:1.4.1",
            "androidx.media3:media3-exoplayer-smoothstreaming:1.4.1",
            "androidx.media3:media3-extractor:1.4.1"
        )
    }
}

flutter {
    source = "../.."
}
