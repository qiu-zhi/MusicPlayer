#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QSettings>
#include <QStandardPaths>
#include <QSysInfo>
#include <QtQuickControls2/QQuickStyle>
#include <QUrl>

#include "src/folderScanner.h"
#include "src/nativeaudioplayer.h"
#include "src/playlistfile.h"

// 接收系统「打开方式」传入的地址：
// 安卓收到 VIEW intent 后会经 QDesktopServices::openUrl 按 scheme 分发处理器，
// 这里注册 content / file 两个 scheme，拿到地址再转发给 QML 播放
class OpenUrlRelay : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;

    Q_INVOKABLE void openUrl(const QUrl &url)
    {
        emit fileOpenRequested(url.toString());
    }

signals:
    void fileOpenRequested(const QString &url);
};

#ifdef Q_OS_WIN
#include <windows.h>
#endif

// 配置目录：两平台各走各的惯例，不刻意统一。
//
//   桌面 → QStandardPaths::AppConfigLocation
//          Windows 展开为 %LOCALAPPDATA%\Music Player（C:\Users\<user>\AppData\Local\...）
//          Linux 展开为 ~/.config/Music Player，macOS 为 ~/Library/Preferences/Music Player
//   安卓 → AppConfigLocation + /musicplayer
//          AppConfigLocation 在安卓上就是沙箱内的 files/settings，末段再补一层
//          全小写无空格 —— 安卓的应用私有文件命名规范要求这样。
//
// ⚠️ 两边都不是应用的安装目录：安装位置由安装器决定（QtIFW 装在 Program Files），
// 配置只归本程序管，两者互不干涉。
static QString configDirPath()
{
#ifdef Q_OS_ANDROID
    // 安卓按平台规范来：AppConfigLocation 在安卓上就是沙箱内的 files/settings，
    // 末段补一层全小写无空格的目录名（安卓对应用私有文件的命名要求）。
    const QString dir = QDir(QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation))
            .filePath(QStringLiteral("musicplayer"));
    QDir().mkpath(dir);
    return dir;
#else
    // 桌面沿用原来的家目录点目录：用户一眼能找到，够用，不改
    const QString dir = QDir(QDir::homePath()).filePath(QStringLiteral(".musicplayer"));
    QDir().mkpath(dir);
    return dir;
#endif
}

// 0.1.2 ~ 0.1.3 在两个平台上都放在「用户主目录下的 .musicplayer/」
// （安卓上 Qt 把 HOME 指向了应用沙箱，见 QtLoader.java:114，所以那里实际是
// files/.musicplayer/）。桌面位置没变，下面的搬迁会因 oldDir == newDir 直接跳过；
// 只有安卓需要把旧目录搬进新位置。
static const char *const kConfigFileNames[] = {
    "config.ini", "playlist.json", ".migrated-from-registry"
};

// 旧目录 → 新目录。同名冲突时以新位置为准（旧目录只补缺）。
// 搬完删掉旧目录，避免两份配置并存、用户改了 A 却读到 B。
static void migrateLegacyConfigDir(const QString &newDir)
{
    const QString oldDir = QDir(QDir::homePath()).filePath(QStringLiteral(".musicplayer"));
    if (oldDir == newDir)
        return;

    QDir old(oldDir);
    if (!old.exists())
        return;

    QDir dst(newDir);
    bool moved = false;
    for (const char *name : kConfigFileNames) {
        const QString n = QString::fromLatin1(name);
        if (!old.exists(n))
            continue;
        const QString target = dst.filePath(n);
        if (dst.exists(target))
            QFile::remove(target);
        if (!old.rename(n, target))
            QFile::copy(old.filePath(n), target);
        moved = true;
    }

    if (moved && !old.removeRecursively())
        qWarning() << "[config] 旧配置目录未能删除，请手动清理：" << oldDir;
}

#ifdef Q_OS_WIN
// 递归删掉历史注册表子树。
// 用 RegDeleteTree 而不是 RegDeleteKey：后者遇到子键会失败，
// 而 QSettings 的布局里 <app> 下面还有 <category> 子键。
// 只有确认旧数据已迁移（或本来就没有）才会走到这里，不会误删还有用的数据。
static void removeLegacyRegistryTree()
{
    const QString org = QCoreApplication::organizationName();
    const QString app = QCoreApplication::applicationName();
    const QString appPath = QStringLiteral("Software\\%1\\%2").arg(org, app);
    const QString orgPath = QStringLiteral("Software\\%1").arg(org);
    RegDeleteTreeW(HKEY_CURRENT_USER, reinterpret_cast<const wchar_t *>(appPath.utf16()));
    RegDeleteTreeW(HKEY_CURRENT_USER, reinterpret_cast<const wchar_t *>(orgPath.utf16()));
}

// 一次性迁移：旧版本在 Windows 上把配置写在 HKCU\Software\<org>\<app>。
// 把旧值搬进 ini 之后清掉注册表，此后这个程序不再碰注册表。
// 用哨兵文件保证只探测一次 —— 否则每次启动都会因为构造 QSettings 而重新建出空键。
static void migrateLegacyRegistrySettings(const QString &configDir, const QString &iniPath)
{
    const QString sentinel = QDir(configDir).filePath(QStringLiteral(".migrated-from-registry"));
    if (QFile::exists(sentinel))
        return;

    QSettings legacy(QSettings::NativeFormat, QSettings::UserScope,
                     QCoreApplication::organizationName(),
                     QCoreApplication::applicationName());
    const QStringList keys = legacy.allKeys();

    if (!keys.isEmpty() && !QFile::exists(iniPath)) {
        QSettings ini(iniPath, QSettings::IniFormat);
        for (const QString &key : keys)
            ini.setValue(key, legacy.value(key));
        ini.sync();
        if (ini.status() != QSettings::NoError) {
            qWarning() << "[config] 迁移写入失败，保留注册表项：" << iniPath;
            return;                   // 失败就下次启动再试，别丢数据
        }
        qInfo() << "[config] 已把旧注册表配置迁移到" << iniPath;
    }

    removeLegacyRegistryTree();

    QFile marker(sentinel);
    if (marker.open(QIODevice::WriteOnly))
        marker.close();
}
#endif

// 播放列表以前是塞在 config.ini 的 [library] songsJson 里的（QSettings 还会把它
// 再转义一层）。现在改存独立的 playlist.json，这里做一次性搬迁：
// 把旧值原样写进 json 文件，再把 ini 里的键删掉。已有文件就什么都不做。
static void migratePlaylistToJsonFile(const QString &iniPath, const QString &jsonPath)
{
    if (QFile::exists(jsonPath))
        return;

    QSettings ini(iniPath, QSettings::IniFormat);
    const QString legacy = ini.value(QStringLiteral("library/songsJson")).toString();
    if (legacy.isEmpty())
        return;

    QFile file(jsonPath);
    if (!file.open(QIODevice::WriteOnly)) {
        qWarning() << "[config] 播放列表迁移失败，保留 ini 中的旧数据：" << jsonPath;
        return;
    }
    file.write(legacy.toUtf8());
    file.close();

    ini.remove(QStringLiteral("library/songsJson"));
    ini.sync();
    qInfo() << "[config] 播放列表已迁移到" << jsonPath;
}

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    QCoreApplication::setOrganizationName("quz");
    QCoreApplication::setApplicationName("Music Player");
    QCoreApplication::setApplicationVersion(QStringLiteral(APP_VERSION));

    const QString configDir = configDirPath();
    const QString configPath = QDir(configDir).filePath(QStringLiteral("config.ini"));

    // 兜底：任何没显式指定落盘位置的 QSettings 都写文件，不写注册表
    QSettings::setDefaultFormat(QSettings::IniFormat);
    QSettings::setPath(QSettings::IniFormat, QSettings::UserScope, configDir);

    // 旧版本把配置放在「用户主目录/.musicplayer/」，先搬进新位置再往下读
    migrateLegacyConfigDir(configDir);

#ifdef Q_OS_WIN
    migrateLegacyRegistrySettings(configDir, configPath);
#endif

    // 播放列表以前塞在 config.ini 的 [library] songsJson 里，现在改存独立的 JSON 文件
    const QString playlistPath = QDir(configDir).filePath(QStringLiteral("playlist.json"));
    migratePlaylistToJsonFile(configPath, playlistPath);

    // QML 的 XMLHttpRequest 默认禁止读取本地文件，放开后才能加载音乐同目录下的 LRC 歌词
    qputenv("QML_XHR_ALLOW_FILE_READ", "1");

    // 使用 Basic 样式以获得最大的自定义空间
    QQuickStyle::setStyle("Basic");

    OpenUrlRelay openUrlRelay;
#ifdef Q_OS_ANDROID
    QDesktopServices::setUrlHandler(QStringLiteral("content"), &openUrlRelay, "openUrl");
    QDesktopServices::setUrlHandler(QStringLiteral("file"), &openUrlRelay, "openUrl");
#endif

    // 文件夹递归扫描：桌面走 QDir，安卓走 SAF（DocumentsContract）
    FolderScanner folderScanner;
    // 安卓原生播放器：仅安卓可用，Windows 侧走 QMediaPlayer（见 PlaybackEngine.qml）
    NativeAudioPlayer nativePlayer;
    // 播放列表的落盘读写（QML 自己写不了文件）
    PlaylistFile playlistFile(playlistPath);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("fileOpenRelay"), &openUrlRelay);
    engine.rootContext()->setContextProperty(QStringLiteral("folderScanner"), &folderScanner);
    engine.rootContext()->setContextProperty(QStringLiteral("nativePlayer"), &nativePlayer);
    engine.rootContext()->setContextProperty(QStringLiteral("playlistFile"), &playlistFile);
    engine.rootContext()->setContextProperty(QStringLiteral("appVersion"),
                                             QCoreApplication::applicationVersion());
    // QML 的 Settings 组件用它指定落盘位置（不指定就会落到注册表）
    engine.rootContext()->setContextProperty(QStringLiteral("configFile"),
                                             QUrl::fromLocalFile(configPath));

    // 「关于」弹窗的构建信息，例如：
    //   Built on 2026/10/13 based on Qt 6.12 (MinGW 13.1.0, x86_64)
    // 日期与编译器由 CMake 在配置时探测后注入（见 CMakeLists.txt），
    // Qt 版本取编译期版本号，CPU 架构取运行时实际架构 ——
    // 所以同一个弹窗在 Windows 显示 x86_64、在安卓显示 arm64，都是真值而非写死。
    QString buildInfo = QStringLiteral("Built on %1 based on Qt %2.%3 (%4, %5)");
    buildInfo = buildInfo.arg(QStringLiteral(APP_BUILD_DATE))
                         .arg(QT_VERSION_MAJOR)
                         .arg(QT_VERSION_MINOR)
                         .arg(QStringLiteral(APP_COMPILER))
                         .arg(QSysInfo::currentCpuArchitecture());
    engine.rootContext()->setContextProperty(QStringLiteral("buildInfo"), buildInfo);

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() { QCoreApplication::exit(-1); },
                     Qt::QueuedConnection);

    // 直接从内置的 MusicPlayer QML 模块加载入口界面
    engine.loadFromModule("MusicPlayer", "Main");

    return app.exec();
}

#include "main.moc"
