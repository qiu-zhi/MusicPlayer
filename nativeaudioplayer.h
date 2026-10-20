#ifndef NATIVEAUDIOPLAYER_H
#define NATIVEAUDIOPLAYER_H

#include <QObject>
#include <QString>
#include <QTimer>

/**
 * 安卓原生播放器的 Qt 封装。
 *
 * 背景（2026-10-14 真机定位）：
 *   Qt 的安卓音频输出走 AAudio / AudioOut_D(PRIMARY)，HAL 缓冲仅 1024 帧 = 21.3ms；
 *   而系统播放器走 AudioTrack + AUDIO_FLAG_DEEP_BUFFER / AudioOut_15，HAL 缓冲 2048 帧。
 *   当音频采样率与 A2DP 输出（48kHz）一致时是"直通"，我们流里的时序抖动直接打在
 *   21.3ms 的极小余量上 → 蓝牙耳机上切歌 / seek 后持续卡顿（改容量与倍数均无效）。
 *   原生 MediaPlayer 与系统播放器同路，天然避开该问题。
 *
 * 实现方式：通过 JNI 转发到 Java 侧的 AudioBridge / PlaybackService，
 *           状态用 QTimer 轮询拉取（不做反向 JNI 回调，少一层复杂度）。
 *
 * 非安卓平台上 available() 返回 false，调用方应回退到 QMediaPlayer。
 */
class NativeAudioPlayer : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool playing READ playing NOTIFY playingChanged)
    Q_PROPERTY(int position READ position NOTIFY positionChanged)
    Q_PROPERTY(int duration READ duration NOTIFY durationChanged)

public:
    explicit NativeAudioPlayer(QObject *parent = nullptr);

    bool playing() const { return m_playing; }
    int position() const { return m_position; }
    int duration() const { return m_duration; }

    /** 当前平台是否可用（仅安卓为 true）。 */
    Q_INVOKABLE bool available() const;

    /** 打开新源；autoplay 为真则就绪后立即播放。 */
    Q_INVOKABLE void setSource(const QString &url, bool autoplay);
    Q_INVOKABLE void play();
    Q_INVOKABLE void pause();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void seekTo(int ms);
    Q_INVOKABLE void setVolume(qreal volume);

signals:
    void playingChanged();
    void positionChanged();
    void durationChanged();
    void ended();
    void errorOccurred(const QString &message);
    /** 蓝牙/耳机断开、音频即将落到扬声器：播放器已自行暂停，调用方据此同步界面 */
    void outputDeviceLost();

private:
    void poll();

    /**
     * 更新「正在播放」状态镜像，值变化时发 playingChanged。
     *
     * 换源 / 暂停 / 停止都必须走这里，不能直接改 m_playing。
     * 原因：轮询用「边沿检测」上报状态（只有读到的值与镜像不同才发信号），
     * 镜像一旦与真实状态脱节，那个边沿就被吃掉，界面永远等不到翻转
     * （2026-10-20 安卓真机定位：列表点歌后唱机不转、按钮显示「播放」，
     *   而声音其实在放）。详见 .cpp 里 setPlayingState 的说明。
     */
    void setPlayingState(bool playing);

    QTimer m_timer;
    bool m_playing = false;
    int m_position = 0;
    int m_duration = 0;
    QString m_lastUrl;        // 供"打开重试"复用
    int m_retryLeft = 0;      // 剩余重试次数（服务异步启动，首次调用可能落空）
    int m_pendingTicks = 0;   // 打开请求已收到但还没准备好的连续轮询次数（看门狗用）
    int m_deviceTick = 0;     // 输出设备查询的降频计数（见 kDeviceCheckEvery）
    int m_lastDeviceType = -1; // 上次轮询到的输出设备类型（AudioDeviceInfo.TYPE_*）
};

#endif // NATIVEAUDIOPLAYER_H
