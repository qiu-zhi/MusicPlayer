#ifndef FOLDERSCANNER_H
#define FOLDERSCANNER_H

#include <QObject>
#include <QUrl>

#ifdef Q_OS_ANDROID
#include <QJniObject>
#endif

// 与系统（主要是 Android）打交道的桥：
// - 递归扫描文件夹里的音频文件（桌面走 QDir，Android 走 SAF / DocumentsContract）
// - 查询 content:// 地址的显示名与 MIME 类型，供 QML 侧判断格式与命名
// - 申请持久化读取权限，保证重启后地址依然可访问
class FolderScanner : public QObject
{
    Q_OBJECT
public:
    using QObject::QObject;

    // 递归扫描文件夹，返回音频文件的 URL 字符串列表（数量有上限保护）
    Q_INVOKABLE QStringList scanFolder(const QUrl &folder) const;

    // 为选中的文档申请持久化读取权限，应用重启后地址依然可访问（Android 专用，桌面为空操作）
    Q_INVOKABLE void keepPermission(const QUrl &uri) const;

    // content:// 地址的真实文件名（如「周杰伦 - 稻香.mp3」）；拿不到返回空串
    Q_INVOKABLE QString displayName(const QUrl &uri) const;

    // content:// 地址的 MIME 类型（如 audio/mpeg）；拿不到返回空串
    Q_INVOKABLE QString mimeType(const QUrl &uri) const;

    // 地址指向的文件是否仍可访问：Android 走 ContentResolver 试打开，
    // 桌面走文件系统。用于播放前拦截「已被外部删除」的曲目
    Q_INVOKABLE bool fileExists(const QUrl &url) const;

    // 读取音频同目录下的同名 .lrc 歌词内容；找不到返回空串。
    // Android 的音频多为 content:// 地址，需沿 DocumentsContract 找到同目录的
    // 同名文档再读流（QML 的 XHR 读不了 content scheme）
    Q_INVOKABLE QString readLyrics(const QUrl &audioUrl) const;

private:
#ifdef Q_OS_ANDROID
    QStringList scanAndroidTree(const QJniObject &treeUri) const;
    void collectAndroidChildren(const QJniObject &treeUri,
                                const QJniObject &parentDocId,
                                int depth,
                                QStringList &result) const;
    // 向 ContentResolver 取单列字符串（显示名 / MIME 共用）
    QString querySingleColumn(const QUrl &uri, const QString &column) const;
    // 音频是 content:// 时：在同目录里找同名 .lrc 并读回内容
    QString androidLyricsText(const QString &audioUrlString) const;
    // 用 ContentResolver.openInputStream 把整个流读成文本
    QString readStreamText(const QJniObject &uri) const;
#endif
    static bool hasAudioExtension(const QString &name);
};

#endif // FOLDERSCANNER_H
