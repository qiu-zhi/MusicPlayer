#include "nativeaudioplayer.h"

#ifdef Q_OS_ANDROID
#include <QJniObject>
#include <QtCore/qcoreapplication_platform.h>
#endif

namespace {

constexpr int kPollIntervalMs = 200;
constexpr int kMaxOpenRetries = 6;   // 约 1.2 秒内重试打开，兜住"服务尚未就绪"
constexpr int kMaxPendingTicks = 15; // 打开请求已收到但迟迟没准备好时的看门狗（15 × 200ms = 3 秒）
constexpr int kDeviceCheckEvery = 2; // 每 2 次轮询查一次输出设备（400ms）

#ifdef Q_OS_ANDROID
constexpr const char *kBridgeClass = "com/quz/musicplayer/AudioBridge";
#endif

} // namespace

NativeAudioPlayer::NativeAudioPlayer(QObject *parent)
    : QObject(parent)
{
    m_timer.setInterval(kPollIntervalMs);
    connect(&m_timer, &QTimer::timeout, this, &NativeAudioPlayer::poll);

#ifdef Q_OS_ANDROID
    // 把 Application Context 交给 Java 侧（AudioBridge.init 会顺手把服务拉起来）
    const QJniObject ctx = QNativeInterface::QAndroidApplication::context();
    if (ctx.isValid()) {
        QJniObject::callStaticMethod<void>(
                kBridgeClass, "init",
                "(Landroid/content/Context;)V", ctx.object<jobject>());
    }
    m_timer.start();
#endif
}

bool NativeAudioPlayer::available() const
{
#ifdef Q_OS_ANDROID
    return true;
#else
    return false;
#endif
}

void NativeAudioPlayer::setSource(const QString &url, bool autoplay)
{
    // 换源 = 旧歌已停。先把状态镜像归零并**发信号**。
    //
    // 为什么必须在这里归零（2026-10-20 安卓真机定位，根因）：
    //   轮询用「边沿检测」上报状态 —— 只有读到的值与镜像不同才发 playingChanged。
    //   换源时若不动镜像，镜像仍是旧歌的 true；新歌若在下一轮询前就开播
    //   （prepare 比 200ms 轮询快），轮询读到 true == 镜像 true → 不发信号 →
    //   QML 侧那行「engine.playing = false」（切歌时写的）永远等不到翻转 →
    //   界面一直停在「暂停」：唱机不转、按钮显示播放，而声音其实在放。
    //   复现与验证：node tools/verify_playstate_sync.js
    setPlayingState(false);

    // 位置 / 时长同理：换源后立刻归零并发信号。
    // 不发信号的话，QML 那边 positionMs / durationMs 的绑定不会重算，
    // 进度条和时间会一直停在这首歌上。
    if (m_position != 0) {
        m_position = 0;
        emit positionChanged();
    }
    if (m_duration != 0) {
        m_duration = 0;
        emit durationChanged();
    }

#ifdef Q_OS_ANDROID
    const bool haveSource = !url.isEmpty();
    m_lastUrl = url;
    m_retryLeft = autoplay ? kMaxOpenRetries : 0;
    if (!haveSource)
        return;

    const QJniObject jUrl = QJniObject::fromString(url);
    QJniObject::callStaticMethod<void>(
            kBridgeClass, autoplay ? "openAndPlay" : "openOnly",
            "(Ljava/lang/String;)V", jUrl.object<jstring>());

    if (!m_timer.isActive())
        m_timer.start();
#else
    Q_UNUSED(url);
    Q_UNUSED(autoplay);
#endif
}

void NativeAudioPlayer::setPlayingState(bool playing)
{
    if (m_playing == playing)
        return;
    m_playing = playing;
    emit playingChanged();
}

void NativeAudioPlayer::play()
{
#ifdef Q_OS_ANDROID
    QJniObject::callStaticMethod<void>(kBridgeClass, "play", "()V");
    m_retryLeft = kMaxOpenRetries;
    if (!m_timer.isActive())
        m_timer.start();
#endif
}

void NativeAudioPlayer::pause()
{
#ifdef Q_OS_ANDROID
    m_retryLeft = 0;
    QJniObject::callStaticMethod<void>(kBridgeClass, "pause", "()V");
    // 立刻把界面同步成「暂停」，不等下一轮询（最多 200ms 的滞后手感很差）
    setPlayingState(false);
#endif
}

void NativeAudioPlayer::stop()
{
#ifdef Q_OS_ANDROID
    m_retryLeft = 0;
    QJniObject::callStaticMethod<void>(kBridgeClass, "stop", "()V");
    setPlayingState(false);
#endif
}

void NativeAudioPlayer::seekTo(int ms)
{
#ifdef Q_OS_ANDROID
    QJniObject::callStaticMethod<void>(kBridgeClass, "seekTo", "(I)V", jint(ms));
#endif
}

void NativeAudioPlayer::setVolume(qreal volume)
{
#ifdef Q_OS_ANDROID
    QJniObject::callStaticMethod<void>(kBridgeClass, "setVolume", "(F)V", jfloat(volume));
#else
    Q_UNUSED(volume);
#endif
}

void NativeAudioPlayer::poll()
{
#ifdef Q_OS_ANDROID
    // 1) 播放结束 / 错误（一次性消费）
    if (QJniObject::callStaticMethod<jboolean>(kBridgeClass, "consumeCompletion", "()Z")) {
        setPlayingState(false);
        emit ended();
    }

    const QJniObject err = QJniObject::callStaticMethod<jstring>(kBridgeClass, "consumeError", "()Ljava/lang/String;");
    if (err.isValid()) {
        const QString msg = err.toString();
        if (!msg.isEmpty()) {
            emit errorOccurred(msg);
            // 源已经打不开了（文件被删 / 格式不支持）：再重试也是白试，
            // 而且每次重试都会在 Java 侧重建一遍 MediaPlayer，纯属浪费
            m_retryLeft = 0;
        }
    }

    // 2) 轮询状态
    const bool playing = QJniObject::callStaticMethod<jboolean>(kBridgeClass, "isPlaying", "()Z");
    const int pos = QJniObject::callStaticMethod<jint>(kBridgeClass, "getPosition", "()I");
    const int dur = QJniObject::callStaticMethod<jint>(kBridgeClass, "getDuration", "()I");

    if (playing != m_playing) {
        m_playing = playing;
        emit playingChanged();
    }
    if (pos != m_position) {
        m_position = pos;
        emit positionChanged();
    }
    if (dur != m_duration) {
        m_duration = dur;
        emit durationChanged();
    }

    // 3) 输出设备切换：蓝牙 / 耳机断开 → 音频落到扬声器时**暂停**（不外放）。
    //    每次判断都要问 AudioManager（内部是全量枚举），所以只在播放中查、
    //    且降到每 2 次轮询一次（400ms）：断开的最坏"外放"窗口仅 400ms，
    //    查询频率却减半；暂停期间不查，顺便避免把「暂停时换了设备」
    //    误判成「播放中断开」而在恢复播放时立刻弹提示。
    if (playing) {
        if (++m_deviceTick % kDeviceCheckEvery == 0) {
            const int devType = QJniObject::callStaticMethod<jint>(
                    kBridgeClass, "getCurrentDeviceType", "()I");
            if (devType >= 0) {
                auto isBluetooth = [](int t) {
                    // AudioDeviceInfo.TYPE_BLUETOOTH_SCO = 7，TYPE_BLUETOOTH_A2DP = 8
                    return t == 7 || t == 8;
                };
                if (m_lastDeviceType >= 0 && m_lastDeviceType != devType
                        && isBluetooth(m_lastDeviceType) && !isBluetooth(devType)) {
                    QJniObject::callStaticMethod<void>(kBridgeClass, "pause", "()V");
                    setPlayingState(false);
                    emit outputDeviceLost();
                }
                m_lastDeviceType = devType;
            }
        }
    } else {
        m_lastDeviceType = -1;     // 没在播就不知道设备，恢复播放后重新采样
    }

    // 4) 打开重试：**只在请求真的没送达时**才重试。
    //
    //    旧判据是「没在播 + 位置与时长都是 0」—— 而这恰好是「正在 prepare」时的状态，
    //    于是每轮询（200ms）都会把刚建好的 MediaPlayer 拆掉重建
    //    （Java 侧 prepared 仍为 false → setSource 走重建分支），
    //    播放被硬生生推迟 1.2 秒以上，还白白建 6~7 个 player。
    //    现在改问 Java「请求收到了吗」：只有真没收到（服务还没起来）才重试。
    //    回归验证：node tools/verify_playstate_sync.js
    const bool openPending = QJniObject::callStaticMethod<jboolean>(
            kBridgeClass, "isOpenPending", "()Z");
    if (m_retryLeft > 0 && !playing && pos == 0 && dur == 0 && !openPending) {
        --m_retryLeft;
        QJniObject::callStaticMethod<void>(
                kBridgeClass, "openAndPlay",
                "(Ljava/lang/String;)V", QJniObject::fromString(m_lastUrl).object<jstring>());
    } else if (playing || dur > 0 || openPending) {
        m_retryLeft = 0;
    }

    // 5) 看门狗：请求**收到了**但迟迟没准备好（prepare 挂住）时，
    //    超过 3 秒强制重开一次。旧的重试循环顺带提供了这个兜底，
    //    换成精确判据后必须单独补上，否则界面会一直停在「暂停」且没有任何提示。
    if (openPending) {
        if (++m_pendingTicks > kMaxPendingTicks) {
            m_pendingTicks = 0;
            QJniObject::callStaticMethod<void>(
                    kBridgeClass, "openAndPlay",
                    "(Ljava/lang/String;)V", QJniObject::fromString(m_lastUrl).object<jstring>());
        }
    } else {
        m_pendingTicks = 0;
    }
#endif
}
