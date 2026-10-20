// 验证 stepQueue 与原 playNext/playPrev 的行为等价
//
// 不同于 verify_audio_route.js（那套是复刻），这里**直接加载真实实现**
// js/PlayerActions.js，所以重构后如果逻辑被改坏了，这个脚本会立刻报出来。
//
// 跑法：node tools/verify_stepqueue.js

const fs = require('fs')
const path = require('path')

// ---------- 加载真实实现 ----------
// 去掉 QML 的 .pragma library 指令，其余原样 eval，拿到函数本身
const srcPath = path.join(__dirname, '..', 'js', 'PlayerActions.js')
const src = fs.readFileSync(srcPath, 'utf8').replace(/^\s*\.pragma library\s*$/m, '')
const impl = new Function(src + '\nreturn { stepQueue: stepQueue, effectiveQueue: effectiveQueue }')()

// ---------- 重构前的参考实现 ----------
function oldNext(queue, cur, mode, rnd) {
    if (mode === 2) {
        let pick = Math.floor(rnd() * queue.length)
        if (queue.length > 1 && pick === cur) pick = (pick + 1) % queue.length
        return queue[pick]
    }
    return queue[cur < 0 ? 0 : (cur + 1) % queue.length]
}

function oldPrev(queue, cur, mode, rnd) {
    if (mode === 2) {
        return queue[Math.floor(rnd() * queue.length)]
    }
    return queue[cur < 0 ? 0 : (cur - 1 + queue.length) % queue.length]
}

// ---------- 用真实 stepQueue 跑一次，返回它选中的文件 ----------
function runStep(queue, cur, mode, dir, rnd) {
    let picked = null
    const files = queue.slice()

    const root = {
        playQueue: files.slice(),
        currentFile: cur >= 0 ? files[cur] : '',
        currentSongIndex: cur,
        playMode: mode,
        showToast: () => {},
    }
    const store = {
        count: files.length,
        allFiles: () => files.slice(),
        indexOfFile: f => files.indexOf(f),
        songAt: i => ({ file: files[i], title: files[i] }),
        removeFile: () => {},
    }
    const engine = {
        playing: true,
        source: '',
        switchTo: f => { picked = f },
        // 队列只有一首（或随机抽到自己）时走 replay，同样算"选中了这首"
        replay: () => { picked = root.currentFile },
        play: () => {},
        stop: () => {},
        toggle: () => {},
    }
    const ctx = { root, store, engine, lyrics: { source: '' }, fs: null }

    // 真实实现用的是 Math.random，这里换种子做可复现比对
    const realRandom = Math.random
    Math.random = rnd
    try {
        impl.stepQueue(ctx, dir, true)
    } finally {
        Math.random = realRandom
    }
    return picked
}

// 可复现伪随机
function makeRnd(seed) {
    let s = seed
    return () => { s = (s * 1103515245 + 12345) & 0x7fffffff; return s / 0x7fffffff }
}

const queues = [
    ["a"],
    ["a", "b"],
    ["a", "b", "c"],
    ["a", "b", "c", "d", "e"],
]
const modes = [0, 1, 2]

let fails = 0
let total = 0

for (const q of queues) {
    for (const mode of modes) {
        for (let cur = -1; cur < q.length; ++cur) {
            // 下一首
            for (let seed = 1; seed <= 50; ++seed) {
                total++
                const o = oldNext(q, cur, mode, makeRnd(seed))
                const n = runStep(q, cur, mode, 1, makeRnd(seed))
                if (o !== n) {
                    fails++
                    if (fails <= 5) console.log(`NEXT 差异 q=${q} cur=${cur} mode=${mode} seed=${seed}: old=${o} new=${n}`)
                }
            }
            // 上一首
            for (let seed = 1; seed <= 50; ++seed) {
                total++
                const o = oldPrev(q, cur, mode, makeRnd(seed))
                const n = runStep(q, cur, mode, -1, makeRnd(seed))
                if (o !== n) {
                    fails++
                    if (fails <= 5) console.log(`PREV 差异 q=${q} cur=${cur} mode=${mode} seed=${seed}: old=${o} new=${n}`)
                }
            }
        }
    }
}

console.log(`\n共比对 ${total} 组，差异 ${fails} 处`)
console.log(fails === 0 ? "PASS: 真实实现与原行为完全等价" : "FAIL: 存在行为差异")
process.exit(fails === 0 ? 0 : 1)
