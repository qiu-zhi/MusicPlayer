#include "playlistfile.h"

#include <QFile>
#include <QSaveFile>

PlaylistFile::PlaylistFile(const QString &filePath, QObject *parent)
    : QObject(parent)
    , m_path(filePath)
{
}

QString PlaylistFile::read() const
{
    QFile file(m_path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return QString::fromUtf8(file.readAll());
}

bool PlaylistFile::write(const QString &json) const
{
    // QSaveFile 先写临时文件再原子替换：中途崩溃或断电不会留下半个列表
    QSaveFile file(m_path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(json.toUtf8());
    return file.commit();
}
