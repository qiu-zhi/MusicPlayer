package com.quz.musicplayer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.media.AudioPlaybackConfiguration;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * 原生播放服务：用 Android 内置的 MediaPlayer 播放音频。
 *
 * 为什么换成原生播放（2026-10-14 真机定位）：
 *   Qt 的安卓音频输出走 AAudio，落 AudioOut_D（PRIMARY），HAL 缓冲仅 1024 帧 = 21.3ms；
 *   而系统播放器走 AudioTrack + AUDIO_FLAG_DEEP_BUFFER，落 AudioOut_15，HAL 缓冲 2048 帧。
 *   当音频采样率与 A2DP 输出（48kHz）一致时是"直通"，我们流里的时序抖动直接打在
 *   21.3ms 的极小余量上 → 蓝牙耳机上切歌/seek 后持续卡顿。
 *   原生 MediaPlayer 与系统播放器同路，天然避开这个问题。
 *
 * 设计取舍：
 *   · 状态同步用"Qt 侧轮询"而不是反向 JNI 回调 —— 少一层复杂度，够用
 *   · 播放结束/错误用标志位暂存，由 Qt 轮询取走（一次性消费）
 *   · 用前台服务，避免切后台后播放被系统限制（与替换前的行为保持一致）
 */
public class PlaybackService extends Service {

    private static final String TAG = "MP-Playback";
    private static final String CHANNEL_ID = "mp_playback";
    private static final int NOTIFICATION_ID = 1001;

    /** 供 AudioBridge 调用的单例句柄（服务未启动时为 null）。 */
    private static PlaybackService sInstance;

    private volatile MediaPlayer player;
    private volatile Uri currentUri;
    private volatile boolean prepared = false;
    private volatile boolean wantPlayWhenReady = false;
    private volatile boolean completionPending = false;
    private volatile String lastError = "";

    /**
     * 打开请求是否"已收到但还没准备好"。
     *
     * 用途（2026-10-20）：Qt 侧要判断"我的打开请求有没有送达"，
     * 只有真没送达（服务还没起来）才值得重试。
     * 旧判据是"没在播 + 位置时长都是 0" —— 那恰好是"正在 prepare"的状态，
     * 于是每 200ms 就把刚建好的 MediaPlayer 拆掉重建，播放被推迟 1.2 秒以上。
     */
    private volatile boolean openPending = false;

    /**
     * 换源代号：每次创建或释放 MediaPlayer 都递增。
     *
     * 存在的理由（2026-10-16 真机闪退）：MediaPlayer 的 prepare 回调一旦排进消息队列就取消不掉。
     * 快速切歌时 setSource(A) 建的 player 在 setSource(B) 里被 release 掉，
     * 但 A 的 onPrepared 照样会被投递 —— 对已释放的 player 调 start() 就抛
     * IllegalStateException（那次 FATAL EXCEPTION 的根因）。回调开头比对代号即可丢弃过期回调。
     *
     * volatile：状态轮询与播放命令走 Qt 主线程，通知栏的控制走 binder 线程，两边都会读写它。
     */
    private volatile int sourceGeneration = 0;

    // ---------------- 生命周期 ----------------

    @Override
    public void onCreate() {
        super.onCreate();
        sInstance = this;
        createNotificationChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 前台服务：避免切后台被限制（通知内容保持最简，后续接 MediaSession 再丰富）
        startForeground(NOTIFICATION_ID, buildNotification());
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        releasePlayer();
        sInstance = null;
        super.onDestroy();
    }

    // ---------------- 对外静态接口（供 AudioBridge 转发） ----------------

    static void openAndPlay(Context context, String url) {
        PlaybackService svc = ensureService(context);
        if (svc == null) return;
        svc.setSource(url, true);
    }

    static void openOnly(Context context, String url) {
        PlaybackService svc = ensureService(context);
        if (svc == null) return;
        svc.setSource(url, false);
    }

    static void play(Context context) {
        PlaybackService svc = ensureService(context);
        if (svc == null) return;
        if (svc.prepared && svc.player != null) {
            try {
                svc.player.start();
                svc.updateNotification();
            } catch (IllegalStateException e) {
                // player 在 prepared 之后又被换源/释放了，这次 start 作废
                svc.lastError = "start 失败: " + e.getMessage();
                Log.w(TAG, svc.lastError);
            }
        } else {
            svc.wantPlayWhenReady = true;   // 还没 prepare 完，先记下意图
        }
    }

    static void pause(Context context) {
        if (sInstance == null) return;
        sInstance.wantPlayWhenReady = false;
        try {
            if (sInstance.prepared && sInstance.player != null && sInstance.player.isPlaying())
                sInstance.player.pause();
        } catch (IllegalStateException ignored) { }
        sInstance.updateNotification();
    }

    static void stop(Context context) {
        if (sInstance == null) return;
        sInstance.wantPlayWhenReady = false;
        if (sInstance.player != null) {
            try { sInstance.player.stop(); } catch (IllegalStateException ignored) { }
        }
        sInstance.prepared = false;
        sInstance.updateNotification();
    }

    static void seekTo(Context context, int ms) {
        if (sInstance == null || !sInstance.prepared) return;
        try { sInstance.player.seekTo(ms); } catch (IllegalStateException ignored) { }
    }

    static void setVolume(Context context, float volume) {
        if (sInstance == null || !sInstance.prepared) return;
        try { sInstance.player.setVolume(volume, volume); } catch (IllegalStateException ignored) { }
    }

    /**
     * 当前媒体流实际使用的输出设备类型（AudioDeviceInfo.TYPE_*），拿不到返回 -1。
     *
     * 用途：检测"蓝牙断开 → 音频落到扬声器"。用户要求这种场景**暂停**而不是外放。
     *
     * 注：本类曾实现 setPreferredDevice()/clearPreferredDevice()（反射调用
     * AudioManager.setPreferredDeviceForStrategy 来手动指定输出设备），但该方法是
     * **@SystemApi**，普通应用调不动；且安卓不给"指定输出设备"的公开 API
     * （只有 AudioTrack.setPreferredDevice，那需要输出层自己用 AudioTrack 实现）。
     * 因此已在 UI 上隐藏该入口（仅 Windows 开放），相关代码一并删除。
     */
    static int getCurrentDeviceType(Context context) {
        if (context == null) return -1;
        AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (am == null) return -1;
        for (AudioPlaybackConfiguration cfg : am.getActivePlaybackConfigurations()) {
            if (cfg == null) continue;
            AudioAttributes attr = cfg.getAudioAttributes();
            if (attr == null || attr.getUsage() != AudioAttributes.USAGE_MEDIA) continue;
            AudioDeviceInfo dev = cfg.getAudioDeviceInfo();
            if (dev != null) return dev.getType();
        }
        return -1;
    }

    static int getPosition(Context context) {
        if (sInstance == null || !sInstance.prepared) return 0;
        try { return sInstance.player.getCurrentPosition(); } catch (IllegalStateException e) { return 0; }
    }

    static int getDuration(Context context) {
        if (sInstance == null || !sInstance.prepared) return 0;
        try { return sInstance.player.getDuration(); } catch (IllegalStateException e) { return 0; }
    }

    static boolean isPlaying(Context context) {
        if (sInstance == null || !sInstance.prepared) return false;
        try { return sInstance.player.isPlaying(); } catch (IllegalStateException e) { return false; }
    }

    /**
     * 打开请求是否已收到但还没准备好。
     *
     * 服务没起来时返回 false —— 那种情况下请求确实丢了，Qt 侧该重试。
     */
    static boolean isOpenPending(Context context) {
        if (sInstance == null) return false;
        return sInstance.openPending;
    }

    /** 取走"播放结束"标志（一次性消费）。 */
    static boolean consumeCompletion(Context context) {
        if (sInstance == null) return false;
        boolean v = sInstance.completionPending;
        sInstance.completionPending = false;
        return v;
    }

    /** 取走最近一次错误信息（一次性消费，空串表示无错误）。 */
    static String consumeError(Context context) {
        if (sInstance == null) return "";
        String v = sInstance.lastError;
        sInstance.lastError = "";
        return v;
    }

    // ---------------- 内部实现 ----------------

    private static PlaybackService ensureService(Context context) {
        if (sInstance != null) return sInstance;
        if (context == null) return null;
        Intent i = new Intent(context, PlaybackService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(i);
        } else {
            context.startService(i);
        }
        return sInstance;   // 首次调用时可能仍为 null，调用方需容错
    }

    private void setSource(String url, boolean playWhenReady) {
        wantPlayWhenReady = playWhenReady;
        completionPending = false;
        lastError = "";

        final Uri uri;
        try {
            uri = Uri.parse(url);
        } catch (Exception e) {
            lastError = "bad url: " + url;
            return;
        }
        if (currentUri != null && currentUri.equals(uri) && prepared) {
            // 同一个源：直接按需播放，不重建
            openPending = false;
            if (playWhenReady && player != null && !player.isPlaying()) {
                try {
                    player.start();
                } catch (IllegalStateException e) {
                    lastError = "start 失败: " + e.getMessage();
                    Log.w(TAG, lastError);
                }
            }
            return;
        }

        releasePlayer();                 // 代号在这里递增
        currentUri = uri;
        prepared = false;
        openPending = true;              // 请求已收到，等 prepare 回调

        final MediaPlayer mp = new MediaPlayer();
        player = mp;
        final int myGeneration = sourceGeneration;   // 这个 player 的身份

        mp.setAudioAttributes(new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build());

        mp.setOnPreparedListener(p -> {
            if (myGeneration != sourceGeneration)
                return;                     // 已被换源或释放，丢弃这个过期回调
            prepared = true;
            openPending = false;
            if (wantPlayWhenReady) {
                try {
                    p.start();
                } catch (IllegalStateException e) {
                    // 代号也拦不住 release 与回调真正并发的极端情况，这里兜底
                    lastError = "start 失败: " + e.getMessage();
                    Log.w(TAG, lastError);
                }
            }
            updateNotification();
        });
        mp.setOnCompletionListener(p -> completionPending = true);
        mp.setOnErrorListener((p, what, extra) -> {
            lastError = "MediaPlayer error what=" + what + " extra=" + extra;
            prepared = false;
            openPending = false;
            updateNotification();
            return true;
        });

        try {
            mp.setDataSource(getApplicationContext(), uri);
            mp.prepareAsync();
        } catch (Exception e) {
            lastError = "setDataSource/prepare 失败: " + e.getMessage();
            openPending = false;           // 打开失败：不再是"进行中"
            Log.w(TAG, lastError);
        }
    }

    private void releasePlayer() {
        ++sourceGeneration;                // 让所有在途回调失效
        openPending = false;
        if (player != null) {
            try { player.reset(); player.release(); } catch (Exception ignored) { }
            player = null;
        }
        prepared = false;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm == null || nm.getNotificationChannel(CHANNEL_ID) != null) return;
        NotificationChannel ch = new NotificationChannel(
                CHANNEL_ID, "播放", NotificationManager.IMPORTANCE_LOW);
        ch.setShowBadge(false);
        nm.createNotificationChannel(ch);
    }

    private Notification buildNotification() {
        Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        return b.setContentTitle(notificationTitle())
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build();
    }

    /** 通知栏标题跟着真实状态走：没载入曲目时显示应用名，之后在播放/暂停之间切换。 */
    private String notificationTitle() {
        if (player == null || !prepared) return "Music Player";
        boolean playing;
        try {
            playing = player.isPlaying();
        } catch (IllegalStateException e) {
            playing = false;
        }
        return playing ? "正在播放" : "已暂停";
    }

    /** 状态变了就刷新通知（播放/暂停/切歌/出错）。 */
    private void updateNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIFICATION_ID, buildNotification());
    }
}
