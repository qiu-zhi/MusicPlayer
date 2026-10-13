cmake_minimum_required(VERSION 3.16)
project(MusicPlayer VERSION 1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 6.5 COMPONENTS
    Core
    Gui
    Qml
    Quick
    QuickControls2
    Multimedia
    # 歌词文件不少是 GBK/GB18030 编码，用 QTextCodec 解码
    Core5Compat
    REQUIRED
)

qt_add_executable(MusicPlayer
    main.cpp
    folderScanner.cpp
    folderScanner.h
)

# 版本号随 CMake 项目版本走，「关于」弹窗直接展示
target_compile_definitions(MusicPlayer PRIVATE
    APP_VERSION="${PROJECT_VERSION}"
)

qt_add_qml_module(MusicPlayer
    URI MusicPlayer
    VERSION 1.0
    # 资源必须放在默认导入路径 qrc:/qt/qml 下，否则安卓上引擎找不到 qmldir
    RESOURCE_PREFIX "/qt/qml"
    QML_FILES
        Main.qml
        components/VinylRecord.qml
        components/ToneArm.qml
        components/Turntable.qml
        components/IconButton.qml
        components/PlayerControls.qml
        components/LyricsView.qml
        components/PlaylistPanel.qml
        components/PillButton.qml
        components/LibraryPage.qml
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
        assets/icons/repeat.svg
        assets/icons/repeat-one.svg
        assets/icons/shuffle.svg
        assets/icons/chevron-down.svg
        assets/icons/x.svg
        assets/icons/heart.svg
        assets/icons/heart-filled.svg
        assets/icons/plus.svg
        assets/icons/trash.svg
        assets/icons/pencil.svg
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
