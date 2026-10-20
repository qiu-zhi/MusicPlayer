// 播放状态同步的行为验证（安卓链路）
//
// 复刻三段逻辑：
//   ① PlaybackService.java   —— 打开请求 / prepare / start 的时序
//   ② nativeaudioplayer.cpp  —— 状态镜像 m_playing + 轮询边沿检测 + 打开重试
//   ③ PlaybackEngine.qml     —— engine.playing 的写入
//                               （切歌时写 false；playingChanged 信号到达时写镜像值）
//
// 跑法：node tools/verify_playstate_sync.js
//
// 核心不变量：**界面状态最终必须等于真实播放状态**。
//
// 2026-10-20 安卓真机定位到的 bug：换源时 C++ 侧状态镜像没归零，
// 轮询的「边沿检测」把「新歌开播」这个 true 边沿吃掉 ——
// 镜像还是旧歌的 true，新歌开播后轮询读到 true == 镜像 true → 不发信号 →
// QML 侧那行「engine.playing = false」（切歌时写的）永远等不到翻转。
// 表现：安卓从播放列表点歌后，唱机不转、按钮显示「播放」，而声音其实在放。
//
// 脚本同时跑「修前 / 修后」两套模型：修前必须复现失败，修后必须全过 ——
// 这样这个脚本就是回归防线，而不是一次性演示。

const POLL_MS = 200;          // kPollIntervalMs
const MAX_OPEN_RETRIES = 6;   // kMaxOpenRetries
const MAX_PENDING_TICKS = 15; // kMaxPendingTicks（看门狗：3 秒没准备好就强制重开）

// ---------------------------------------------------------------- Java 侧

class FakeService {
    // prepareMs：打开到 prepared 的耗时（content:// 通常几百毫秒）
    // hangFirstOpens：前 N 次打开的 prepare 永远不回调（模拟 prepare 挂住）
    constructor(prepareMs, serviceUpAt, hangFirstOpens = 0) {
        this.prepareMs = prepareMs;
        this.serviceUpAt = serviceUpAt;   // 服务就绪的虚拟时刻
        this.hangFirstOpens = hangFirstOpens;
        this.state = 'none';               // none | preparing | prepared | error
        this.prepareDoneAt = Infinity;
        this.playWhenReady = false;
        this.started = false;
        this.error = '';
        this.playerCount = 0;              // 建过几个 MediaPlayer（换源/重试就 +1）
        this.completion = false;
    }

    get up() { return this.serviceUpAt <= this.now; }
    set now(v) { this._now = v; }
    get now() { return this._now; }

    advance(now) {
        this.now = now;
        if (this.state === 'preparing' && now >= this.prepareDoneAt) {
            this.state = 'prepared';
            if (this.playWhenReady) this.started = true;
        }
    }

    // 对应 PlaybackService.setSource
    open(url, now) {
        if (!this.up) return false;        // 服务还没起来：请求直接丢了
        this.playerCount++;
        this.state = 'preparing';
        this.playWhenReady = true;
        this.started = false;
        this.error = '';
        this.completion = false;
        if (this.hangFirstOpens > 0) {
            // 模拟 prepare 挂住：回调永远不来
            this.hangFirstOpens--;
            this.prepareDoneAt = Infinity;
            return true;
        }
        this.prepareDoneAt = now + this.prepareMs;
        return true;
    }

    isPlaying() { return this.state === 'prepared' && this.started; }
    isOpenPending() { return this.state === 'preparing'; }
    getPosition() { return this.state === 'prepared' ? 1000 : 0; }
    getDuration() { return this.state === 'prepared' ? 180000 : 0; }
    errorText() { const e = this.error; this.error = ''; return e; }
    consumeCompletion() { const c = this.completion; this.completion = false; return c; }
}

// ---------------------------------------------------------------- C++ 侧

class NativePlayer {
    // fix = false：修前逻辑（镜像不归零 + 宽泛的重试判据）
    // fix = true ：修后逻辑
    constructor(svc, fix) {
        this.svc = svc;
        this.fix = fix;
        this.m_playing = false;
        this.m_position = 0;
        this.m_duration = 0;
        this.m_lastUrl = '';
        this.m_retryLeft = 0;
        this.m_pendingTicks = 0;
        this.emitted = [];      // 记录 playingChanged 的发射次数
    }

    get playing() { return this.m_playing; }
    get position() { return this.m_position; }
    get duration() { return this.m_duration; }

    // 信号出口：QML 侧只在 playingChanged 发射时才同步 engine.playing。
    // 这一条是整个 bug 的要害 —— 界面的值是「事件驱动」的，
    // 不是「每帧从镜像拉取」的，所以镜像漏发一次信号，界面就永远停在旧值。
    onPlayingChanged = null;
    // 同理：positionMs / durationMs 是 QML 绑定，只在 NOTIFY 信号到达时才重算。
    onPositionChanged = null;

    setPlayingState(v) {
        if (this.m_playing === v) return;
        this.m_playing = v;
        this.emitted.push(v);
        if (this.onPlayingChanged) this.onPlayingChanged();
    }

    // 对应 NativeAudioPlayer::setSource
    setSource(url, autoplay) {
        this.m_lastUrl = url;
        if (this.fix) {
            // 修后：换源即「旧歌已停」—— 镜像归零并发信号
            this.setPlayingState(false);
            if (this.m_position !== 0) { this.m_position = 0; this.emitPosition(); }
            if (this.m_duration !== 0) { this.m_duration = 0; this.emitPosition(); }
        }
        this.m_position = 0;
        this.m_duration = 0;
        this.m_retryLeft = autoplay ? MAX_OPEN_RETRIES : 0;
        if (!url) return;
        this.svc.open(url, this.svc.now);
    }

    emitPosition() {
        if (this.onPositionChanged) this.onPositionChanged();
    }

    pause() {
        this.m_retryLeft = 0;
        this.svc.playWhenReady = false;
        this.svc.started = false;
        if (this.fix) this.setPlayingState(false);
    }

    play() {
        this.m_retryLeft = MAX_OPEN_RETRIES;
        this.svc.playWhenReady = true;
        if (this.svc.state === 'prepared') this.svc.started = true;
    }

    // 对应 NativeAudioPlayer::poll
    poll() {
        if (this.svc.consumeCompletion()) {
            this.m_playing = false;
            this.emitted.push(false);
            if (this.onPlayingChanged) this.onPlayingChanged();
        }
        const err = this.svc.errorText();
        if (err) this.m_retryLeft = 0;      // 修后：失败的源不再重试

        const playing = this.svc.isPlaying();
        const pos = this.svc.getPosition();
        const dur = this.svc.getDuration();

        if (playing !== this.m_playing) {
            this.m_playing = playing;
            this.emitted.push(playing);
            if (this.onPlayingChanged) this.onPlayingChanged();
        }
        if (pos !== this.m_position) { this.m_position = pos; this.emitPosition(); }
        if (dur !== this.m_duration) { this.m_duration = dur; this.emitPosition(); }

        // 打开重试
        const openPending = this.fix ? this.svc.isOpenPending() : false;
        if (this.m_retryLeft > 0 && !playing && pos === 0 && dur === 0 && !openPending) {
            this.m_retryLeft--;
            this.svc.open(this.m_lastUrl, this.svc.now);
        } else if (playing || dur > 0 || openPending) {
            this.m_retryLeft = 0;
        }

        // 看门狗：请求收到了但迟迟没准备好 → 超过 3 秒强制重开
        if (this.fix) {
            if (openPending) {
                if (++this.m_pendingTicks > MAX_PENDING_TICKS) {
                    this.m_pendingTicks = 0;
                    this.svc.open(this.m_lastUrl, this.svc.now);
                }
            } else {
                this.m_pendingTicks = 0;
            }
        }
    }
}

// ---------------------------------------------------------------- QML 侧

class Engine {
    constructor(player) {
        this.player = player;
        this.playing = false;         // engine.playing
        this.source = '';
        // Connections.onPlayingChanged：只有信号到达才写 engine.playing
        player.onPlayingChanged = () => { this.playing = player.playing; };
        // positionMs / durationMs 是绑定：只有 NOTIFY 信号到达才重算，
        // 所以界面上看到的进度是「最后一次信号时的值」
        this.uiPosition = 0;
        this.uiDuration = 0;
        player.onPositionChanged = () => {
            this.uiPosition = player.position;
            this.uiDuration = player.duration;
        };
    }
    // PlaybackEngine.switchTo
    switchTo(url, autoplay) {
        this.source = url;
        if (!this.fixMode) {
            this.playing = false;     // 修前：安卓路径也写 false（与镜像脱节）
        }
        // 修后：安卓路径不直接写 engine.playing，交给 nativePlayer 的镜像驱动
        this.player.setSource(url, autoplay);
    }
}

// ---------------------------------------------------------------- 场景

function runScenario(fix, scenario) {
    const svc = new FakeService(scenario.prepareMs ?? 300, scenario.serviceUpAt ?? 0,
                               scenario.hangFirstOpens ?? 0);
    svc.now = 0;
    const player = new NativePlayer(svc, fix);
    const engine = new Engine(player);
    engine.fixMode = fix;
    let afterSwitch = null;

    let now = 0;
    const tick = () => {
        now += POLL_MS;
        svc.advance(now);
        player.poll();
    };

    for (const step of scenario.steps) {
        if (step.at !== undefined) {
            while (now < step.at) tick();
        }
        if (step.action === 'switchTo') {
            engine.switchTo(step.url, step.autoplay !== false);
            // 记录「切歌那一刻」界面上看到的进度 / 时长：
            // 换源后必须立刻归零，否则进度条还停在上一首
            afterSwitch = { pos: engine.uiPosition, dur: engine.uiDuration };
        } else if (step.action === 'play') {
            player.play();
        } else if (step.action === 'pause') {
            player.pause();
        } else if (step.action === 'fail') {
            svc.state = 'error';
            svc.error = 'MediaPlayer error';
            svc.started = false;
        }
    }
    // 静置：让状态稳定
    const settle = scenario.settle ?? 20;
    for (let i = 0; i < settle; i++) tick();

    return {
        uiPlaying: engine.playing,
        realPlaying: svc.isPlaying(),
        uiPosition: engine.uiPosition,
        realPosition: svc.getPosition(),
        afterSwitch,
        playerCount: svc.playerCount,
        elapsed: now,
    };
}

const SCENARIOS = [
    {
        name: '① 冷启动：库里没在播的，点歌开播',
        prepareMs: 300,
        steps: [{ action: 'switchTo', url: 'a.mp3' }],
        expect: { uiPlaying: true, realPlaying: true },
    },
    {
        name: '② 播放中从列表点另一首（核心场景）',
        prepareMs: 120,            // prepare 比轮询快 → 新歌在下一轮询前就开播
        steps: [
            { action: 'switchTo', url: 'a.mp3' },
            { at: 800, action: 'switchTo', url: 'b.mp3' },
        ],
        expect: { uiPlaying: true, realPlaying: true },
        expectAfterSwitch: { pos: 0, dur: 0 },   // 进度条 / 时长必须立刻归零
    },
    {
        name: '③ 播放中切歌，prepare 很慢（> 轮询周期）',
        prepareMs: 900,
        steps: [
            { action: 'switchTo', url: 'a.mp3' },
            { at: 2000, action: 'switchTo', url: 'b.mp3' },
        ],
        expect: { uiPlaying: true, realPlaying: true },
        expectAfterSwitch: { pos: 0, dur: 0 },
    },
    {
        name: '④ 暂停后再播',
        prepareMs: 200,
        steps: [
            { action: 'switchTo', url: 'a.mp3' },
            { at: 1000, action: 'pause' },
            { at: 1600, action: 'play' },
        ],
        expect: { uiPlaying: true, realPlaying: true },
    },
    {
        name: '⑤ 切歌后立刻暂停（prepare 期间点暂停）',
        prepareMs: 400,
        steps: [
            { action: 'switchTo', url: 'a.mp3' },
            { at: 800, action: 'switchTo', url: 'b.mp3' },
            { at: 900, action: 'pause' },
        ],
        expect: { uiPlaying: false, realPlaying: false },
    },
    {
        name: '⑥ 打开失败：源已失效',
        prepareMs: 200,
        steps: [
            { action: 'switchTo', url: 'a.mp3' },
            { at: 100, action: 'fail' },
        ],
        expect: { uiPlaying: false, realPlaying: false },
    },
    {
        name: '⑦ 服务尚未就绪（请求丢失 → 重试兜住）',
        prepareMs: 200,
        serviceUpAt: 600,
        steps: [{ action: 'switchTo', url: 'a.mp3' }],
        expect: { uiPlaying: true, realPlaying: true },
    },
    {
        name: '⑧ prepare 挂住（看门狗兜底：3 秒后强制重开）',
        prepareMs: 200,
        hangFirstOpens: 1,        // 第一次打开的 prepare 永远不回调
        steps: [{ action: 'switchTo', url: 'a.mp3' }],
        expect: { uiPlaying: true, realPlaying: true },
    },
];

// ---------------------------------------------------------------- 主流程

let failures = 0;

function check(scenario, r) {
    const problems = [];
    if (r.uiPlaying !== scenario.expect.uiPlaying)
        problems.push(`界面 playing=${r.uiPlaying}（期望 ${scenario.expect.uiPlaying}）`);
    if (r.realPlaying !== scenario.expect.realPlaying)
        problems.push(`真实 playing=${r.realPlaying}（期望 ${scenario.expect.realPlaying}）`);
    if (scenario.expectAfterSwitch) {
        if (r.afterSwitch.pos !== scenario.expectAfterSwitch.pos)
            problems.push(`切歌后进度停在 ${r.afterSwitch.pos}ms（期望 ${scenario.expectAfterSwitch.pos}）`);
        if (r.afterSwitch.dur !== scenario.expectAfterSwitch.dur)
            problems.push(`切歌后时长停在 ${r.afterSwitch.dur}ms（期望 ${scenario.expectAfterSwitch.dur}）`);
    }
    return problems;
}

console.log('═══ 修前逻辑（复刻 nativeaudioplayer.cpp 旧实现）═══\n');
for (const s of SCENARIOS) {
    const r = runScenario(false, s);
    const problems = check(s, r);
    if (problems.length) failures++;
    console.log(`${problems.length ? ' FAIL ' : '  ok  '} ${s.name}`);
    console.log(`        界面 playing=${r.uiPlaying}  真实 playing=${r.realPlaying}`
        + `  建 player 次数=${r.playerCount}  用时=${r.elapsed}ms`);
    for (const p of problems) console.log(`        ↳ ${p}`);
}

console.log('\n═══ 修后逻辑（本次改动）═══\n');
let fixFailures = 0;
for (const s of SCENARIOS) {
    const r = runScenario(true, s);
    const problems = check(s, r);
    if (problems.length) fixFailures++;
    console.log(`${problems.length ? ' FAIL ' : '  ok  '} ${s.name}`);
    console.log(`        界面 playing=${r.uiPlaying}  真实 playing=${r.realPlaying}`
        + `  建 player 次数=${r.playerCount}  用时=${r.elapsed}ms`);
    for (const p of problems) console.log(`        ↳ ${p}`);
}

console.log('');
if (failures === 0) {
    console.log('⚠ 修前逻辑竟然全过了 —— 复现失效，场景参数需要重新校准（别信这个结果）');
    process.exit(1);
}
if (fixFailures > 0) {
    console.log(`✗ 修后逻辑仍有 ${fixFailures} 个场景不过 —— 改动没解决问题`);
    process.exit(1);
}
console.log(`✓ 修前 ${failures} 个场景复现失败 / 修后全部通过 —— 根因确认，改动有效`);
