package com.quz.musicplayer;

import android.content.Context;
import android.content.Intent;
import android.os.Build;

/**
 * JNI 入口：Qt 侧通过这些静态方法控制原生播放。
 *
 * 调用约定（Qt 侧用 QAndroidJniObject::callStaticMethod）：
 *   com/quz/musicplayer/AudioBridge  init(Landroid/content/Context;)V
 *   ...                              openAndPlay(Ljava/lang/String;)V
 *   ...                              play()V / pause()V / stop()V
 *   ...                              seekTo(I)V  / setVolume(F)V
 *   ...                              getPosition()I / getDuration()I / isPlaying()Z
 *   ...                              isOpenPending()Z
 *   ...                              consumeCompletion()Z / consumeError()Ljava/lang/String;
 *
 * 说明：状态同步采用「Qt 侧轮询」而非反向 JNI 回调 —— 少一层复杂度，够用。
 */
public class AudioBridge {

    private static Context sContext;

    /** Qt 启动时调用一次，传入 Application Context（后续所有操作都基于它）。 */
    public static void init(Context context) {
        if (context == null) return;
        sContext = context.getApplicationContext();

        // 提前把服务拉起来：服务是异步创建的，若等到第一次播放才启动，
        // 那一次调用会落在 sInstance == null 上而静默失败。
        try {
            Intent i = new Intent(sContext, PlaybackService.class);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                sContext.startForegroundService(i);
            } else {
                sContext.startService(i);
            }
        } catch (Exception ignored) {
            // 启动失败不影响后续调用（那时 sInstance 仍可能为 null，由各方法自行容错）
        }
    }

    // ---------- 播放控制 ----------

    public static void openAndPlay(String url) {
        if (sContext != null) PlaybackService.openAndPlay(sContext, url);
    }

    public static void openOnly(String url) {
        if (sContext != null) PlaybackService.openOnly(sContext, url);
    }

    public static void play() {
        if (sContext != null) PlaybackService.play(sContext);
    }

    public static void pause() {
        PlaybackService.pause(null);
    }

    public static void stop() {
        PlaybackService.stop(null);
    }

    public static void seekTo(int ms) {
        PlaybackService.seekTo(null, ms);
    }

    public static void setVolume(float volume) {
        PlaybackService.setVolume(null, volume);
    }

    // ---------- 状态查询（Qt 侧轮询） ----------

    public static int getPosition() {
        return PlaybackService.getPosition(null);
    }

    public static int getDuration() {
        return PlaybackService.getDuration(null);
    }

    public static boolean isPlaying() {
        return PlaybackService.isPlaying(null);
    }

    /**
     * 打开请求是否已收到但还没准备好。
     *
     * Qt 侧据此判断"请求有没有送达"：只有真没送达（服务还没起来）才重试，
     * 否则每 200ms 的轮询都会把正在 prepare 的 MediaPlayer 拆掉重建。
     */
    public static boolean isOpenPending() {
        return PlaybackService.isOpenPending(null);
    }

    /** 取走"播放结束"标志（一次性消费）。 */
    public static boolean consumeCompletion() {
        return PlaybackService.consumeCompletion(null);
    }

    /** 取走最近一次错误（一次性消费，空串表示无错误）。 */
    public static String consumeError() {
        return PlaybackService.consumeError(null);
    }

    /** 当前媒体流实际使用的输出设备类型（AudioDeviceInfo.TYPE_*），拿不到返回 -1。 */
    public static int getCurrentDeviceType() {
        return PlaybackService.getCurrentDeviceType(sContext);
    }
}
