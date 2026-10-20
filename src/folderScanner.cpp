#include "folderScanner.h"

#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QDebug>
#include <QFutureWatcher>
#include <QTextCodec>
#include <QtConcurrent/QtConcurrentRun>
#include <QtCore/qcoreapplication_platform.h>

#include <exception>

#ifdef Q_OS_ANDROID
#include <QJniEnvironment>
#include <QJniObject>
#endif

namespace {

// 与 PlaylistStore.audioExtensions / AddMusicDialogs 的过滤器同源：
// QML 侧一律通过 audioSuffixes() 取，别再各写一份
const QStringList kAudioSuffixes = {
    QStringLiteral("mp3"), QStringLiteral("flac"), QStringLiteral("wav"),
    QStringLiteral("m4a"), QStringLiteral("aac"), QStringLiteral("ogg"),
    QStringLiteral("wma"), QStringLiteral("ape"), QStringLiteral("opus")
};

// 防止异常目录结构把扫描拖死：文件总数上限两端都生效；
// 递归深度上限只用于安卓（DocumentsContract 逐层递归），
// 桌面走 QDirIterator::Subdirectories，没有深度限制
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

void FolderScanner::scanFolderAsync(const QUrl &folder)
{
    auto *watcher = new QFutureWatcher<QStringList>(this);
    connect(watcher, &QFutureWatcher<QStringList>::finished,
            this, [this, watcher] {
        emit scanFinished(watcher->result());
        watcher->deleteLater();
    });
    // scanFolder 是 const 的、只依赖参数，可以直接丢给工作线程。
    // 安卓上它走 ContentResolver；QtConcurrent 的工作线程由 QAndroidJniEnv
    // 自动 attach 到 JVM，不必回主线程。
    watcher->setFuture(QtConcurrent::run([this, folder] {
        // 扫描会碰文件系统与 ContentResolver，异常一律就地消化：
        // 穿透到 QFuture 会让 result() 重新抛出，等于把崩溃搬到 GUI 线程。
        try {
            return scanFolder(folder);
        } catch (const std::exception &e) {
            qWarning() << "[scan] 扫描异常:" << e.what();
        } catch (...) {
            qWarning() << "[scan] 扫描异常（类型未知）";
        }
        return QStringList();
    }));
}

QStringList FolderScanner::audioSuffixes() const
{
    return kAudioSuffixes;
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

#ifdef Q_OS_ANDROID
// 读走并清除当前挂起的 JNI 异常，返回异常类名（无异常返回空串）。
//
// 存在的意义：必须把「文件真的不在了」(FileNotFoundException) 与
// 「读不到」(SecurityException：URI 读取权限失效；或 provider 不支持 openFile)
// 区分开。前者可以清理，后者绝不能当成文件已删除。
static QString takePendingJniExceptionName()
{
    QJniEnvironment env;
    if (!env->ExceptionCheck())
        return QString();

    jthrowable throwable = env->ExceptionOccurred();
    env->ExceptionClear();
    if (!throwable)
        return QString();

    QString name;
    // 走 Throwable.getClass().getName() 拿异常类名
    jclass cls = env->GetObjectClass(throwable);
    if (cls) {
        jmethodID getName = env->GetMethodID(cls, "getName", "()Ljava/lang/String;");
        if (getName && !env->ExceptionCheck()) {
            jstring jname = static_cast<jstring>(env->CallObjectMethod(cls, getName));
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
            } else if (jname) {
                const char *utf = env->GetStringUTFChars(jname, nullptr);
                if (utf) {
                    name = QString::fromUtf8(utf);
                    env->ReleaseStringUTFChars(jname, utf);
                }
                env->DeleteLocalRef(jname);
            }
        }
        env->DeleteLocalRef(cls);
    }
    env->DeleteLocalRef(throwable);
    return name;
}
#endif

QString FolderScanner::bluetoothA2dpDeviceId() const
{
#ifndef Q_OS_ANDROID
    return {};
#else
    // 向 AudioManager 问当前在线的 A2DP 设备 id。
    //
    // 为什么需要它（源码依据见 qtmultimedia/src/multimedia/android/）：
    // ① 安卓的 defaultAudioOutput 是设备枚举的第一个（qandroidaudiodevices.cpp 里
    //    isDefault = i == 0），顺序由系统决定，真机上取到过不可用的设备，表现为无声；
    // ② QAudioOutput 构造、以及 setDevice() 传空设备，都会回退到这个默认值
    //    （qaudiooutput.cpp:62 / :208），公共 API 无法把设备设成"不指定"；
    // ③ Qt 给 A2DP 与 SCO 的 description 都是 "Bluetooth"，QML 侧分不出来，
    //    而 SCO 是蓝牙通话通道（HFP），拿它放音乐会没有声音。
    //
    // 安卓选路已改由系统接管（见 PlaybackEngine.useNative），这里只保留查询能力备查。

    QJniObject context = QNativeInterface::QAndroidApplication::context();
    if (!context.isValid())
        return {};

    QJniObject audioManager = context.callObjectMethod(
            "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;",
            QJniObject::fromString(QStringLiteral("audio")).object<jstring>());
    if (!audioManager.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    const jint getOutputs = QJniObject::getStaticField<jint>(
            "android/media/AudioManager", "GET_DEVICES_OUTPUTS");
    QJniObject devices = audioManager.callObjectMethod(
            "getDevices", "(I)[Landroid/media/AudioDeviceInfo;", getOutputs);
    if (!devices.isValid()) {
        QJniEnvironment().checkAndClearExceptions();
        return {};
    }

    const jint a2dpType = QJniObject::getStaticField<jint>(
            "android/media/AudioDeviceInfo", "TYPE_BLUETOOTH_A2DP");

    QJniEnvironment env;
    jobjectArray array = devices.object<jobjectArray>();
    if (!array)
        return {};

    QString result;
    const jsize count = env->GetArrayLength(array);
    for (jsize i = 0; i < count; ++i) {
        // GetObjectArrayElement / GetObjectClass 返回的都是**局部引用**，
        // 循环里必须逐个 DeleteLocalRef，否则局部引用表溢出会直接崩
        // （本项目之前在 JNI 引用上栽过 SIGSEGV）
        jobject element = env->GetObjectArrayElement(array, i);
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
            continue;
        }
        if (!element)
            continue;

        jclass cls = env->GetObjectClass(element);
        jmethodID typeId = cls ? env->GetMethodID(cls, "getType", "()I") : nullptr;
        jmethodID idId = cls ? env->GetMethodID(cls, "getId", "()I") : nullptr;
        if (cls)
            env->DeleteLocalRef(cls);
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
            env->DeleteLocalRef(element);
            continue;
        }

        bool isA2dp = false;
        if (typeId) {
            const jint type = env->CallIntMethod(element, typeId);
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
            } else {
                isA2dp = (type == a2dpType);
            }
        }

        if (isA2dp && idId) {
            const jint id = env->CallIntMethod(element, idId);
            if (env->ExceptionCheck())
                env->ExceptionClear();
            else
                result = QString::number(id);
        }

        env->DeleteLocalRef(element);
        if (!result.isEmpty())
            break;                       // 找到第一个 A2DP 就够
    }

    return result;
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
        // 必须立刻读走并清掉异常：一是为了判断失败原因，二是挂起的异常会带崩后续 JNI 调用
        const QString openError = takePendingJniExceptionName();
        if (opened)
            return true;

        // 2) 有些 provider 不支持 openFile，退一步问 MIME：拿得到类型说明条目还在
        const QJniObject type = resolver.callObjectMethod(
            "getType", "(Landroid/net/Uri;)Ljava/lang/String;", docUri.object<jobject>());
        const bool hasType = type.isValid() && !type.toString().isEmpty();
        const QString typeError = takePendingJniExceptionName();
        if (hasType)
            return true;

        // 只有 provider 明确报 FileNotFoundException 才算「文件真没了」。
        // SecurityException（URI 读取权限失效）之类都只是「查不出来」，
        // 早先一律返回 false，结果是把好好的歌当失效曲目删掉 ——
        // 用户看到的就是「播放时提示歌曲不存在」。这里改成保守放行。
        const bool gone = openError.endsWith(QLatin1String("FileNotFoundException"));
        qWarning() << "[fileExists]" << (gone ? "确认不存在，可清理:" : "无法确认，按存在处理:")
                   << urlString
                   << "| open:" << (openError.isEmpty() ? QStringLiteral("无异常") : openError)
                   << "| type:" << (typeError.isEmpty() ? QStringLiteral("无异常") : typeError);
        return !gone;
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
