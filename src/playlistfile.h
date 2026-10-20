#ifndef PLAYLISTFILE_H
#define PLAYLISTFILE_H

#include <QObject>
#include <QString>

/**
 * 播放列表的落盘读写。
 *
 * 播放列表是一整段 JSON，单独存成 <配置目录>/playlist.json。
 * 之前塞在 config.ini 的 [library] songsJson 里，QSettings 会把它再转义一层，
 * 文件没法直接看、也没法手改。零散偏好（播放模式、输出设备）仍留在 config.ini。
 *
 * QML 侧没有写文件的能力，所以这里暴露成 context property 给 PlaylistStore 用。
 */
class PlaylistFile : public QObject
{
    Q_OBJECT
public:
    explicit PlaylistFile(const QString &filePath, QObject *parent = nullptr);

    /** 读取播放列表 JSON 文本；文件不存在或打不开时返回空串。 */
    Q_INVOKABLE QString read() const;

    /** 整体覆盖写入（先写临时文件再原子替换）；成功返回 true。 */
    Q_INVOKABLE bool write(const QString &json) const;

private:
    QString m_path;
};

#endif // PLAYLISTFILE_H
