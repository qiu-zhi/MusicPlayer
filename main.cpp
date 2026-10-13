#include <QDesktopServices>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QtQuickControls2/QQuickStyle>
#include <QUrl>

#include "folderScanner.h"

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

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    QCoreApplication::setOrganizationName("quz");
    QCoreApplication::setApplicationName("Music Player");
    QCoreApplication::setApplicationVersion(QStringLiteral(APP_VERSION));

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

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("fileOpenRelay"), &openUrlRelay);
    engine.rootContext()->setContextProperty(QStringLiteral("folderScanner"), &folderScanner);
    engine.rootContext()->setContextProperty(QStringLiteral("appVersion"),
                                             QCoreApplication::applicationVersion());

    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() { QCoreApplication::exit(-1); },
                     Qt::QueuedConnection);

    // 直接从内置的 MusicPlayer QML 模块加载入口界面
    engine.loadFromModule("MusicPlayer", "Main");

    return app.exec();
}

#include "main.moc"
