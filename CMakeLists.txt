cmake_minimum_required(VERSION 3.16)
project(MusicPlayer VERSION 0.1.3 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

# SafeArea 要求 Qt 6.9 起：本项目用的是 `SafeArea.margins` 单例形式
# （Main.qml / OutputDeviceSheet / PlaylistPanel 都在用），它随 6.9 才提供的
# qquicksafearea 一同引入（qquicksafearea.cpp 标注 \since 6.9）。
# 注意与更早的「Item.SafeArea 附加属性」区分开，那不是同一个东西。
find_package(Qt6 6.9 COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    Multimedia
    # 歌词文件不少是 GBK/GB18030 编码，用 QTextCodec 解码
    Core5Compat
    # 文件夹扫描放到工作线程，避免阻塞 UI（见 folderScanner.scanFolderAsync）
    Concurrent
    REQUIRED
)

qt_add_executable(MusicPlayer
    main.cpp
    src/folderScanner.cpp
    src/folderScanner.h
    src/nativeaudioplayer.cpp
    src/nativeaudioplayer.h
    src/playlistfile.cpp
    src/playlistfile.h
)

# src/ 下的头文件按「仓库根是包含路径」来引用（main.cpp 里写 "src/xxx.h"，
# src/ 内部互相引用仍用 "xxx.h"）。这样源码放哪个目录都不影响彼此的相对引用。
target_include_directories(MusicPlayer PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# ---------- 构建信息（「关于」弹窗展示）----------
# 构建日期取 CMake 配置时刻：改 CMakeLists 或重新配置时会自动刷新，
# 不必再手写死日期。
string(TIMESTAMP APP_BUILD_DATE "%Y/%m/%d")

# 编译器名与版本取自当前工具链，所以 Windows 包显示 MinGW、安卓包显示 Clang，
# 同一份代码两平台各自正确，不需要手动区分。
if(MINGW)
    set(APP_COMPILER "MinGW ${CMAKE_CXX_COMPILER_VERSION}")
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
    set(APP_COMPILER "Clang ${CMAKE_CXX_COMPILER_VERSION}")
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    set(APP_COMPILER "GCC ${CMAKE_CXX_COMPILER_VERSION}")
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
    set(APP_COMPILER "MSVC ${CMAKE_CXX_COMPILER_VERSION}")
else()
    set(APP_COMPILER "${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}")
endif()

# 版本号随 CMake 项目版本走，「关于」弹窗直接展示
target_compile_definitions(MusicPlayer PRIVATE
    APP_VERSION="${PROJECT_VERSION}"
    APP_BUILD_DATE="${APP_BUILD_DATE}"
    APP_COMPILER="${APP_COMPILER}"
)

# ---------- Android 打包元信息 ----------
# 注意：上面那个 APP_VERSION 只影响「关于」弹窗（编译期宏），
# Android 桌面图标名与 APK 版本号走的是另一条链路，必须在这里单独指定，
# 否则 androiddeployqt 会落到它源码里硬编码的默认值
# （qtbase/src/tools/androiddeployqt/main.cpp:1184/1192 → 版本名 "1.0"、版本号 "1"；
#   :1424 → 应用名回退成可执行文件名 "MusicPlayer"）。
#
# ANDROID_VERSION_CODE 必须是「只增不减」的整数：Android 靠它判断可否覆盖安装，
# 每次发版手动 +1。0.1 用过 2，0.1.1 用过 3，本版 0.1.2 用 4。
set(ANDROID_VERSION_CODE 5)
# 版本名展示给用户看，跟随 CMake 项目版本（改 project(... VERSION x.y) 即可自动同步）
set(ANDROID_VERSION_NAME "${PROJECT_VERSION}")
# 桌面图标下的名字。此处必须显式给，否则填的是可执行文件名 "MusicPlayer"（缺空格）
set(ANDROID_APP_NAME "Music Player")

set_target_properties(MusicPlayer PROPERTIES
    QT_ANDROID_VERSION_CODE "${ANDROID_VERSION_CODE}"
    QT_ANDROID_VERSION_NAME "${ANDROID_VERSION_NAME}"
    QT_ANDROID_APP_NAME     "${ANDROID_APP_NAME}"
)

# Theme 是单例（pragma Singleton），必须在 qt_add_qml_module 之前声明
set_source_files_properties(components/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(MusicPlayer
    URI MusicPlayer
    VERSION 1.0
    # 资源必须放在默认导入路径 qrc:/qt/qml 下，否则安卓上引擎找不到 qmldir
    RESOURCE_PREFIX "/qt/qml"
    QML_FILES
        Main.qml
        js/PlayerActions.js
        js/DeviceUtils.js
        js/Format.js
        components/TopBar.qml
        components/Theme.qml
        components/LyricsPage.qml
        components/VinylRecord.qml
        components/ToneArm.qml
        components/Turntable.qml
        components/IconButton.qml
        components/PlayerControls.qml
        components/LyricsView.qml
        components/PlaylistPanel.qml
        components/PillButton.qml
        components/ModalDimmer.qml
        components/CheckBoxDot.qml
        components/PlaylistStore.qml
        components/PlaybackEngine.qml
        components/LyricsLoader.qml
        components/AppToast.qml
        components/MenuRow.qml
        components/MoreMenu.qml
        components/AboutDialog.qml
        components/PlayerView.qml
        components/AddMusicDialogs.qml
        components/OutputDeviceSheet.qml
        components/FormatIcon.qml
    RESOURCES
        assets/icons/play.svg
        assets/icons/pause.svg
        assets/icons/skip-back.svg
        assets/icons/skip-forward.svg
        assets/icons/list.svg
        assets/icons/trash.svg
        assets/icons/repeat.svg
        assets/icons/repeat-one.svg
        assets/icons/shuffle.svg
        assets/icons/chevron-down.svg
        assets/icons/heart.svg
        assets/icons/heart-filled.svg
        assets/icons/plus.svg
        assets/icons/music-note.svg
        assets/icons/check.svg
        assets/icons/more-vertical.svg
        assets/icons/folder.svg
        assets/icons/info.svg
        assets/icons/speaker.svg
        assets/icons/headphone.svg
        assets/images/cut/turntable-base.png
        assets/images/cut/vinyl-record.png
        assets/images/cut/tonearm.png
        assets/app-icon/ic_launcher_play_store_512.png
)

target_link_libraries(MusicPlayer PRIVATE
    Qt6::Core
    Qt6::Gui
    Qt6::Qml
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Multimedia
    Qt6::Core5Compat
    Qt6::Concurrent
)

if(WIN32)
    set_target_properties(MusicPlayer PROPERTIES
        WIN32_EXECUTABLE TRUE
    )
    # Windows 应用图标：.rc 里的相对路径按 -I 搜索目录解析，指向源码根
    target_sources(MusicPlayer PRIVATE app.rc)
    target_include_directories(MusicPlayer PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
endif()

if(ANDROID)
    set_target_properties(MusicPlayer PROPERTIES
        QT_ANDROID_PACKAGE_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/android
    )
endif()
