// 验证 stepQueue 合并后与原 playNext/playPrev 行为等价
// 只比对"选曲结果"，随机模式用固定种子做可复现对比

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

function newStep(queue, cur, mode, dir, rnd) {
    if (mode === 2) {
        let pick = Math.floor(rnd() * queue.length)
        if (dir > 0 && queue.length > 1 && pick === cur)
            pick = (pick + 1) % queue.length
        return queue[pick]
    }
    return queue[cur < 0 ? 0 : (cur + dir + queue.length) % queue.length]
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
                const n = newStep(q, cur, mode, 1, makeRnd(seed))
                if (o !== n) {
                    fails++
                    if (fails <= 5) console.log(`NEXT 差异 q=${q} cur=${cur} mode=${mode} seed=${seed}: old=${o} new=${n}`)
                }
            }
            // 上一首
            for (let seed = 1; seed <= 50; ++seed) {
                total++
                const o = oldPrev(q, cur, mode, makeRnd(seed))
                const n = newStep(q, cur, mode, -1, makeRnd(seed))
                if (o !== n) {
                    fails++
                    if (fails <= 5) console.log(`PREV 差异 q=${q} cur=${cur} mode=${mode} seed=${seed}: old=${o} new=${n}`)
                }
            }
        }
    }
}

console.log(`\n共比对 ${total} 组，差异 ${fails} 处`)
console.log(fails === 0 ? "PASS: 合并后行为与原实现完全等价" : "FAIL: 存在行为差异")
