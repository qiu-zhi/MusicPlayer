#include "folderScanner.h"

#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <QTextCodec>
#include <QtCore/qcoreapplication_platform.h>

#ifdef Q_OS_ANDROID
#include <QJniEnvironment>
#include <QJniObject>
#endif

namespace {

// 与 PlaylistStore.audioExtensions 保持一致：能识别的音频后缀
const QStringList kAudioSuffixes = {
    QStringLiteral("mp3"), QStringLiteral("flac"), QStringLiteral("wav"),
    QStringLiteral("m4a"), QStringLiteral("aac"), QStringLiteral("ogg"),
    QStringLiteral("wma"), QStringLiteral("ape"), QStringLiteral("opus")
};

// 防止异常目录结构把扫描拖死：递归深度与文件总数双重上限
constexpr int kMaxDepth = 8;
constexpr int kMaxFiles = 5000;

bool hasAudioSuffix(const QString &name)
{
    const QFileInfo info(name);
    const QString suffix = info.suffix().toLower();
    return suffix.isEmpty() ? false : kAudioSuffixes.contains(suffix);
}

// 由音频文件名推出同名的歌词文件名：xxx.mp3 → xxx.lrc
QString lyricsNameFor(const QString &audioName)
{
    const int dot = audioName.lastIndexOf(QLatin1Char('.'));
    const QString stem = dot > 0 ? audioName.left(dot) : audioName;
    return stem + QStringLiteral(".lrc");
}

// 歌词文本解码：优先看 BOM，其次按 UTF-8；中文歌词大量仍是 GBK/GB18030，
// UTF-8 解出替换字符时退回 GB18030，最后才用 Latin-1 兜底
QString decodeLyrics(const QByteArray &bytes)
{
    if (bytes.isEmpty())
        return {};

    if (bytes.startsWith("\xEF\xBB\xBF"))
        return QString::fromUtf8(bytes.mid(3));

    if (bytes.size() >= 2) {
        const int b0 = static_cast<uchar>(bytes.at(0));
        const int b1 = static_cast<uchar>(bytes.at(1));
        if (b0 == 0xFF && b1 == 0xFE) {
            const QByteArray body = bytes.mid(2);
            return QString::fromUtf16(reinterpret_cast<const char16_t *>(body.constData()),
                                      body.size() / 2);
        }
    }

    const QString utf8 = QString::fromUtf8(bytes);
    if (!utf8.contains(QChar::ReplacementCharacter))
        return utf8;

    if (QTextCodec *codec = QTextCodec::codecForName("GB18030"))
        return codec->toUnicode(bytes);

    return QString::fromLatin1(bytes);
}

#ifdef Q_OS_ANDROID
// 把 URL 字符串转成真正的 android.net.Uri。
// 注意：QJniObject::fromString 得到的是 java.lang.String，
// 直接当 Uri 传给 DocumentResolve / ContentResolver 会因参数类型不符而全部失败
QJniObject uriFromString(const QString &urlString)
{
    const QJniObject text = QJniObject::fromString(urlString);
    if (!text.isValid())
        return {};
    return QJniObject::callStaticMethod<QJniObject>(
        "android/net/Uri", "parse", "(Ljava/lang/String;)Landroid/net/Uri;",
        text.object<jstring>());
}

QJniObject contentResolver()
{
    QJniObject context = QNativeInterface::QAndroidApplication::context();
    if (!context.isValid())
        return {};
    return context.callObjectMethod("getContentResolver",
                                    "()Landroid/content/ContentResolver;");
}
#endif // Q_OS_ANDROID

} // namespace

bool FolderScanner::hasAudioExtension(const QString &name)
{
    return hasAudioSuffix(name);
}

QStringList FolderScanner::scanFolder(const QUrl &folder) const
{
    const QString urlString = folder.toString();
    if (urlString.isEmpty())
        return {};

#ifdef Q_OS_ANDROID
    // Android 端文件夹选择器返回 content:// 树地址，必须走 DocumentsContract
    if (urlString.startsWith(QLatin1String("content:"))) {
        const QJniObject treeUri = uriFromString(urlString);
        if (!treeUri.isValid()) {
            qWarning() << "[scanFolder] Uri.parse 失败:" << urlString;
            return {};
        }
        const QStringList result = scanAndroidTree(treeUri);
        qWarning() << "[scanFolder] 树地址" << urlString << "扫描到" << result.size() << "个音频文件";
        return result;
    }
#endif

    const QString localPath = folder.toLocalFile();
    if (localPath.isEmpty())
        return {};

    QStringList nameFilters;
    for (const QString &suffix : kAudioSuffixes)
        nameFilters << QStringLiteral("*.") + suffix;

    QStringList result;
    QDirIterator it(localPath, nameFilters, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext() && result.size() < kMaxFiles) {
        const QString path = it.next();
        result.append(QUrl::fromLocalFile(path).toString());
    }
    return result;
}

void FolderScanner::keepPermission(const QUrl &uri) const
{
#ifdef Q_OS_ANDROID
    const QString urlString = uri.toString();
    if (!urlString.startsWith(QLatin1String("content:")))
        return;

    const QJniObject resolver = contentResolver();
    if (!resolver.isValid())
        return;

    const QJniObject docUri = uriFromString(urlString);
    if (!docUri.isValid())
        return;

    const jint flags = QJniObject::getStaticField<jint>(
        "android/content/Intent", "FLAG_GRANT_READ_URI_PERMISSION");
    resolver.callMethod<void>("takePersistableUriPermission",
                              "(Landroid/net/Uri;I)V",
                              docUri.object<jobject>(), flags);

    // 权限可能已被系统回收，失败不影响主流程，静默清除异常即可
    QJniEnvironment().checkAndClearExceptions();
#else
    Q_UNUSED(uri)
#endif
}

QString FolderScanner::displayName(const QUrl &uri) const
{
#ifdef Q_OS_ANDROID
    return querySingleColumn(uri, QStringLiteral("_display_name"));
#else
    Q_UNUSED(uri)
    return {};
#endif
}

QString FolderScanner::mimeType(const QUrl &uri) const
{
#ifdef Q_OS_ANDROID
    const QString urlString = uri.toString();
    if (!urlString.startsWith(QLatin1String("content:")))
        return {};

    const QJniObject resolver = contentResolver();
    if (!resolver.isValid())
        return {};

    const QJniObject docUri = uriFromString(urlString);
    if (!docUri.isValid())
        return {};

    // 直接问 ContentResolver 要 MIME，比查 Cursor 更省事
    const QJniObject type = resolver.callObjectMethod(
        "getType", "(Landroid/net/Uri;)Ljava/lang/String;", docUri.object<jobject>());
    QJniEnvironment().checkAndClearExceptions();
    return type.isValid() ? type.toString() : QString();
#else
    Q_UNUSED(uri)
    return {};
#endif
}

bool FolderScanner::fileExists(const QUrl &url) const
{
    const QString urlString = url.toString();
    if (urlString.isEmpty())
        return false;

#ifdef Q_OS_ANDROID
    if (urlString.startsWith(QLatin1String("content:"))) {
        const QJniObject resolver = contentResolver();
        const QJniObject docUri = uriFromString(urlString);
        if (!resolver.isValid() || !docUri.isValid()) {
            // 环境异常时不做判断：宁可放行让播放器自己报错，也不能把好好的曲目误删
            return true;
        }

        // 1) 能打开就说明文件还在（最贴近「到底能不能播」的判据）
        const QJniObject fd = resolver.callObjectMethod(
            "openAssetFileDescriptor",
            "(Landroid/net/Uri;Ljava/lang/String;)Landroid/content/res/AssetFileDescriptor;",
            docUri.object<jobject>(),
            QJniObject::fromString(QStringLiteral("r")).object<jstring>());
        const bool opened = fd.isValid();
        if (opened)
            fd.callMethod<void>("close", "()V");
        // 文件被删时 provider 会抛 FileNotFoundException：必须把异常清掉，
        // 否则后续所有 JNI 调用都会被这个 pending 异常带崩
        QJniEnvironment().checkAndClearExceptions();
        if (opened)
            return true;

        // 2) 少数 provider 不支持 openFile，退一步问 MIME：拿得到类型说明条目还在
        const QJniObject type = resolver.callObjectMethod(
            "getType", "(Landroid/net/Uri;)Ljava/lang/String;", docUri.object<jobject>());
        const bool hasType = type.isValid() && !type.toString().isEmpty();
        QJniEnvironment().checkAndClearExceptions();
        return hasType;
    }
#endif

    const QString localPath = url.toLocalFile();
    if (localPath.isEmpty())
        return false;
    return QFileInfo::exists(localPath);
}

QString FolderScanner::readLyrics(const QUrl &audioUrl) const
{
    const QString urlString = audioUrl.toString();
    if (urlString.isEmpty())
        return {};

#ifdef Q_OS_ANDROID
    // 音频是 content://（SAF 文档 / 媒体库）：沿 DocumentsContract 找同目录的同名文档
    if (urlString.startsWith(QLatin1String("content:")))
        return androidLyricsText(urlString);
#endif

    // 本地文件：同目录同名 .lrc（顺带兼容大写扩展名）
    const QString localPath = audioUrl.toLocalFile();
    if (localPath.isEmpty())
        return {};

    const int slash = qMax(localPath.lastIndexOf(QLatin1Char('/')),
                           localPath.lastIndexOf(QLatin1Char('\\')));
    const QString dir = slash >= 0 ? localPath.left(slash + 1) : QString();
    const QString name = slash >= 0 ? localPath.mid(slash + 1) : localPath;
    const int dot = name.lastIndexOf(QLatin1Char('.'));
    const QString stem = dot > 0 ? name.left(dot) : name;

    const QStringList candidates = { dir + stem + QStringLiteral(".lrc"),
                                     dir + stem + QStringLiteral(".LRC") };
    for (const QString &path : candidates) {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly))
            continue;
        const QByteArray bytes = file.readAll();
        file.close();
        return decodeLyrics(bytes);
    }
    return {};
}

#ifdef Q_OS_ANDROID

QString FolderScanner::querySingleColumn(const QUrl &uri, const QString &column) const{
    const QString urlString = uri.toString();
    if (!urlString.startsWith(QLatin1String("content:")))
        return {};

    const QJniObject resolver = contentResolver();
    if (!resolver.isValid())
        return {};

    const QJniObject docUri = uriFromString(urlString);
    if (!docUri.isValid())
        return {};

    // 不传 projection：取全部列后按列名取值。
    // 之前手工 NewObjectArray/SetObjectArrayElement 拼 String[] 会因本地引用失效直接段错误
    const QJniObject cursor = resolver.callObjectMethod(
        "query",
        "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)"
        "Landroid/database/Cursor;",
        docUri.object<jobject>(), nullptr, nullptr, nullptr, nullptr);

    QString value;
    if (cursor.isValid()) {
        const jint index = cursor.callMethod<jint>(
            "getColumnIndex", "(Ljava/lang/String;)I",
            QJniObject::fromString(column).object<jstring>());
        if (index >= 0 && cursor.callMethod<jboolean>("moveToFirst", "()Z")) {
            const QJniObject text = cursor.callObjectMethod(
                "getString", "(I)Ljava/lang/String;", index);
            if (text.isValid())
                value = text.toString();
        }
        cursor.callMethod("close", "()V");
    }

    QJniEnvironment().checkAndClearExceptions();
    return value;
}

QStringList FolderScanner::scanAndroidTree(const QJniObject &treeUri) const
{
    QStringList result;
    if (!treeUri.isValid())
        return result;

    // 树地址本身也要持久化，否则重启后无法再进入该文件夹
    const QJniObject treeString = treeUri.callObjectMethod("toString", "()Ljava/lang/String;");
    if (treeString.isValid())
        keepPermission(QUrl(treeString.toString()));

    const QJniObject docId = QJniObject::callStaticMethod<QJniObject>(
        "android/provider/DocumentsContract", "getTreeDocumentId",
        "(Landroid/net/Uri;)Ljava/lang/String;", treeUri.object<jobject>());
    if (!docId.isValid()) {
        qWarning() << "[scanFolder] getTreeDocumentId 失败（不是树地址？）";
        QJniEnvironment().checkAndClearExceptions();
        return result;
    }

    collectAndroidChildren(treeUri, docId, 0, result);
    return result;
}

void FolderScanner::collectAndroidChildren(const QJniObject &treeUri,
                                           const QJniObject &parentDocId,
                                           int depth,
                                           QStringList &result) const
{
    if (depth > kMaxDepth || result.size() >= kMaxFiles)
        return;

    // 子文档集合地址：content://.../tree/xxx/document/xxx%2Fchildren
    const QJniObject childrenUri = QJniObject::callStaticMethod<QJniObject>(
        "android/provider/DocumentsContract", "buildChildDocumentsUriUsingTree",
        "(Landroid/net/Uri;Ljava/lang/String;)Landroid/net/Uri;",
        treeUri.object<jobject>(), parentDocId.object<jobject>());
    if (!childrenUri.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return;
    }

    const QJniObject resolver = contentResolver();
    if (!resolver.isValid())
        return;

    // 不传 projection：取全部列后按列名取值（避免手工拼 JNI 数组导致的引用失效崩溃）
    const QJniObject cursor = resolver.callObjectMethod(
        "query",
        "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)"
        "Landroid/database/Cursor;",
        childrenUri.object<jobject>(), nullptr, nullptr, nullptr, nullptr);
    if (!cursor.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return;
    }

    const jint idColumn = cursor.callMethod<jint>(
        "getColumnIndex", "(Ljava/lang/String;)I",
        QJniObject::fromString(QStringLiteral("document_id")).object<jstring>());
    const jint nameColumn = cursor.callMethod<jint>(
        "getColumnIndex", "(Ljava/lang/String;)I",
        QJniObject::fromString(QStringLiteral("_display_name")).object<jstring>());
    const jint mimeColumn = cursor.callMethod<jint>(
        "getColumnIndex", "(Ljava/lang/String;)I",
        QJniObject::fromString(QStringLiteral("mime_type")).object<jstring>());

    // DocumentsContract.Document.MIME_TYPE_DIR
    const QString dirMime = QStringLiteral("vnd.android.document.dir");

    while (cursor.callMethod<jboolean>("moveToNext", "()Z")) {
        if (result.size() >= kMaxFiles)
            break;

        const QJniObject id = cursor.callObjectMethod(
            "getString", "(I)Ljava/lang/String;", idColumn);
        if (!id.isValid())
            continue;

        QString mime;
        if (mimeColumn >= 0) {
            const QJniObject mimeValue = cursor.callObjectMethod(
                "getString", "(I)Ljava/lang/String;", mimeColumn);
            if (mimeValue.isValid())
                mime = mimeValue.toString();
        }

        QString name;
        if (nameColumn >= 0) {
            const QJniObject nameValue = cursor.callObjectMethod(
                "getString", "(I)Ljava/lang/String;", nameColumn);
            if (nameValue.isValid())
                name = nameValue.toString();
        }

        if (mime == dirMime) {
            collectAndroidChildren(treeUri, id, depth + 1, result);
        } else if (mime.startsWith(QLatin1String("audio/")) || hasAudioSuffix(name)) {
            const QJniObject fileUri = QJniObject::callStaticMethod<QJniObject>(
                "android/provider/DocumentsContract", "buildDocumentUriUsingTree",
                "(Landroid/net/Uri;Ljava/lang/String;)Landroid/net/Uri;",
                treeUri.object<jobject>(), id.object<jobject>());
            if (fileUri.isValid())
                result.append(fileUri.toString());
        }
    }

    cursor.callMethod("close", "()V");
    QJniEnvironment().checkAndClearExceptions();
}

QString FolderScanner::androidLyricsText(const QString &audioUrlString) const
{
    const QJniObject docUri = uriFromString(audioUrlString);
    if (!docUri.isValid())
        return {};

    // 文档 ID 形如 primary:Download/xxx.mp3，父目录即去掉最后一段
    const QJniObject docIdObj = QJniObject::callStaticMethod<QJniObject>(
        "android/provider/DocumentsContract", "getDocumentId",
        "(Landroid/net/Uri;)Ljava/lang/String;", docUri.object<jobject>());
    if (!docIdObj.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    const QString docId = docIdObj.toString();
    const int slash = docId.lastIndexOf(QLatin1Char('/'));
    if (slash < 0) {
        // 扁平音乐库（MediaDocumentsProvider 的 audio:4211 之类）没有目录层级，
        // 从文档 ID 里推不出「同目录」，只能放弃
        return {};
    }

    const QString parentId = docId.left(slash);
    const QString lrcName = lyricsNameFor(docId.mid(slash + 1));

    const QJniObject resolver = contentResolver();
    if (!resolver.isValid())
        return {};

    // 列举同目录，按显示名找同名 .lrc（忽略大小写）
    const QJniObject childrenUri = QJniObject::callStaticMethod<QJniObject>(
        "android/provider/DocumentsContract", "buildChildDocumentsUriUsingTree",
        "(Landroid/net/Uri;Ljava/lang/String;)Landroid/net/Uri;",
        docUri.object<jobject>(), QJniObject::fromString(parentId).object<jstring>());
    if (!childrenUri.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    const QJniObject cursor = resolver.callObjectMethod(
        "query",
        "(Landroid/net/Uri;[Ljava/lang/String;Ljava/lang/String;[Ljava/lang/String;Ljava/lang/String;)"
        "Landroid/database/Cursor;",
        childrenUri.object<jobject>(), nullptr, nullptr, nullptr, nullptr);
    if (!cursor.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    const jint idColumn = cursor.callMethod<jint>(
        "getColumnIndex", "(Ljava/lang/String;)I",
        QJniObject::fromString(QStringLiteral("document_id")).object<jstring>());
    const jint nameColumn = cursor.callMethod<jint>(
        "getColumnIndex", "(Ljava/lang/String;)I",
        QJniObject::fromString(QStringLiteral("_display_name")).object<jstring>());

    QString lrcDocId;
    if (idColumn >= 0 && nameColumn >= 0) {
        while (cursor.callMethod<jboolean>("moveToNext", "()Z")) {
            const QJniObject nameObj = cursor.callObjectMethod(
                "getString", "(I)Ljava/lang/String;", nameColumn);
            if (!nameObj.isValid())
                continue;
            if (nameObj.toString().compare(lrcName, Qt::CaseInsensitive) != 0)
                continue;
            const QJniObject idObj = cursor.callObjectMethod(
                "getString", "(I)Ljava/lang/String;", idColumn);
            if (idObj.isValid()) {
                lrcDocId = idObj.toString();
                break;
            }
        }
    }
    cursor.callMethod("close", "()V");
    QJniEnvironment().checkAndClearExceptions();

    if (lrcDocId.isEmpty())
        return {};

    const QJniObject lrcUri = QJniObject::callStaticMethod<QJniObject>(
        "android/provider/DocumentsContract", "buildDocumentUriUsingTree",
        "(Landroid/net/Uri;Ljava/lang/String;)Landroid/net/Uri;",
        docUri.object<jobject>(), QJniObject::fromString(lrcDocId).object<jstring>());
    if (!lrcUri.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    // 1) Qt 在 Android 上注册了 content:// 的文件引擎，QFile 可直接读
    const QJniObject lrcUriString = lrcUri.callObjectMethod("toString", "()Ljava/lang/String;");
    if (lrcUriString.isValid()) {
        QFile file(lrcUriString.toString());
        if (file.open(QIODevice::ReadOnly)) {
            const QByteArray bytes = file.readAll();
            file.close();
            if (!bytes.isEmpty()) {
                qWarning() << "[readLyrics] 命中同目录歌词" << lrcUriString.toString();
                return decodeLyrics(bytes);
            }
        }
    }

    // 2) 兜底：直接问 ContentResolver 要输入流
    const QString text = readStreamText(lrcUri);
    if (!text.isEmpty())
        qWarning() << "[readLyrics] 经输入流读到歌词" << docId;
    return text;
}

QString FolderScanner::readStreamText(const QJniObject &uri) const
{
    const QJniObject resolver = contentResolver();
    if (!resolver.isValid())
        return {};

    const QJniObject stream = resolver.callObjectMethod(
        "openInputStream", "(Landroid/net/Uri;)Ljava/io/InputStream;",
        uri.object<jobject>());
    if (!stream.isValid()) {
        // 文件不存在 / 无权限时这里会抛异常，必须清掉
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    QJniEnvironment env;
    QByteArray bytes;
    constexpr jint kChunk = 16384;
    constexpr int kMaxBytes = 2 * 1024 * 1024;   // 歌词不该这么大，防止跑飞

    jbyteArray buffer = env->NewByteArray(kChunk);
    if (!buffer) {
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    const jclass streamClass = env->GetObjectClass(stream.object<jobject>());
    const jmethodID readMethod = streamClass
            ? env->GetMethodID(streamClass, "read", "([B)I") : nullptr;
    const jmethodID closeMethod = streamClass
            ? env->GetMethodID(streamClass, "close", "()V") : nullptr;

    if (readMethod) {
        while (bytes.size() < kMaxBytes) {
            const jint read = env->CallIntMethod(stream.object<jobject>(), readMethod, buffer);
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
                break;
            }
            if (read <= 0)
                break;
            QByteArray chunk(int(read), Qt::Uninitialized);
            env->GetByteArrayRegion(buffer, 0, read, reinterpret_cast<jbyte *>(chunk.data()));
            bytes.append(chunk);
        }
    }
    if (closeMethod)
        env->CallVoidMethod(stream.object<jobject>(), closeMethod);

    env->DeleteLocalRef(buffer);
    if (streamClass)
        env->DeleteLocalRef(streamClass);
    QJniEnvironment().checkAndClearExceptions();

    return decodeLyrics(bytes);
}

#endif // Q_OS_ANDROID
