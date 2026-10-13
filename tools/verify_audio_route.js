// 设备路由逻辑行为验证（蓝牙优先版）
// 复现 PlaybackEngine.qml 的 resolveTargetDevice + refreshAudioRoute 决策，
// 覆盖「有线 + 蓝牙同时连接」「蓝牙断开」「插拔有线」等场景。
// 跑法：node tools/verify_audio_route.js

const SPEAKER = { id: "speaker", description: "Speaker (Realtek Audio)" };
const HEADPHONE = { id: "headphone", description: "Headphone (Realtek Audio)" };
const HDMI = { id: "hdmi", description: "VX2478-2 (Display Audio)" };
const BLUETOOTH = { id: "bt-a2dp", description: "Bluetooth A2DP Headphones" };

// ---------- 目标实现（蓝牙优先） ----------
function isBluetooth(d) {
  const t = (d.description + " " + d.id).toLowerCase();
  return t.includes("bluetooth") || t.includes("a2dp");
}

// resolveTargetDevice 的独立实现（带 allowFallback 语义）
function resolveTarget(outputs, defaultDev, currentId, outputMode, allowFallback) {
  const curId = currentId;
  const bt = outputs.find(isBluetooth) || null;
  const btId = bt ? bt.id : "";
  const defId = defaultDev && defaultDev.id ? defaultDev.id : "";
  const manualMode = outputMode && outputMode !== "auto";
  const alive = curId !== "" && outputs.some(d => d.id === curId);

  if (manualMode) {
    const wanted = outputs.find(d => d.id === outputMode) || null;
    if (wanted) {
      if (wanted.id === curId) return null;
      return wanted;
    }
  }

  if (bt && btId !== curId) return bt;
  if (bt && btId === curId) return null;

  if (curId !== "" && !alive) {
    if (!allowFallback) return null;      // 被动刷新：不回落
  }

  if (defId === "") return null;
  if (curId === "" || curId !== defId) return defaultDev;
  return null;
}

function route(outputs, defaultDev, currentId, playing, stale, outputMode) {
  const curId = currentId;
  const alive = curId !== "" && outputs.some(d => d.id === curId);
  const bt = outputs.find(isBluetooth) || null;
  const btId = bt ? bt.id : "";
  const defId = defaultDev && defaultDev.id ? defaultDev.id : "";
  const manualMode = outputMode && outputMode !== "auto";
  const wanted = manualMode ? outputs.find(d => d.id === outputMode) || null : null;

  // --- refreshAudioRoute 的快速返回（force=false） ---
  if (curId !== "" && alive && !stale) {
    const manualWants = manualMode && outputMode !== curId && wanted !== null;
    const btWantsToTake = !manualMode && bt && btId !== curId;
    const defChanged = defId !== "" && curId !== defId;
    if (!manualWants && !btWantsToTake && !defChanged) return { op: "none" };
  }

  const target = resolveTarget(outputs, defaultDev, currentId, outputMode, false);
  if (target) return { op: "applyRoute", to: target.id };

  if (!alive) return { op: playing ? "pause+stale" : "stale" };
  return { op: "none" };
}

// ---------- 场景 ----------
const S = [
  {
    name: "①【用户报的 bug】有线+蓝牙同时连接，当前绑扬声器 → 应抢蓝牙",
    outputs: [HEADPHONE, BLUETOOTH, HDMI, SPEAKER], defaultDev: HEADPHONE,
    currentId: "speaker", playing: true, stale: false,
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "② 有线+蓝牙同时连接，当前已绑蓝牙 → 保持不动",
    outputs: [HEADPHONE, BLUETOOTH, HDMI, SPEAKER], defaultDev: HEADPHONE,
    currentId: "bt-a2dp", playing: true, stale: false,
    expect: { op: "none" },
  },
  {
    name: "③ 有线+蓝牙同时连接，当前绑有线耳机 → 抢蓝牙",
    outputs: [HEADPHONE, BLUETOOTH, HDMI, SPEAKER], defaultDev: HEADPHONE,
    currentId: "headphone", playing: true, stale: false,
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "④ 只有有线耳机（无蓝牙），系统默认已切耳机 → 跟默认",
    outputs: [HEADPHONE, HDMI, SPEAKER], defaultDev: HEADPHONE,
    currentId: "speaker", playing: true, stale: false,
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "⑤ 只有有线耳机，当前已绑耳机 → 保持不动（防自激）",
    outputs: [HEADPHONE, HDMI, SPEAKER], defaultDev: HEADPHONE,
    currentId: "headphone", playing: true, stale: false,
    expect: { op: "none" },
  },
  {
    name: "⑥ 蓝牙断开（从列表消失），正在播放 → 暂停 + stale（不自动回落）",
    outputs: [HEADPHONE, HDMI, SPEAKER], defaultDev: HEADPHONE,
    currentId: "bt-a2dp", playing: true, stale: false,
    expect: { op: "pause+stale" },
  },
  {
    name: "⑦ 蓝牙断开后用户点播放（recoverRoute）→ 回落系统默认",
    outputs: [HEADPHONE, HDMI, SPEAKER], defaultDev: HEADPHONE,
    currentId: "bt-a2dp", playing: false, stale: true,
    recover: true,
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "⑧ 只有扬声器，当前绑扬声器 → 保持不动",
    outputs: [HDMI, SPEAKER], defaultDev: SPEAKER,
    currentId: "speaker", playing: true, stale: false,
    expect: { op: "none" },
  },
  {
    name: "⑨ 首启未绑定，有蓝牙 → 直接绑蓝牙",
    outputs: [HEADPHONE, BLUETOOTH, SPEAKER], defaultDev: HEADPHONE,
    currentId: "", playing: false, stale: false,
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "⑩ 首启未绑定，无蓝牙 → 绑系统默认",
    outputs: [HEADPHONE, SPEAKER], defaultDev: HEADPHONE,
    currentId: "", playing: false, stale: false,
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "⑪ 有线耳机拔掉，当前绑耳机，无蓝牙 → 暂停 + stale（不自动回落）",
    outputs: [HDMI, SPEAKER], defaultDev: SPEAKER,
    currentId: "headphone", playing: true, stale: false,
    expect: { op: "pause+stale" },
  },
  {
    name: "⑫ 有线耳机拔掉后用户点播放 → 回落默认（扬声器）",
    outputs: [HDMI, SPEAKER], defaultDev: SPEAKER,
    currentId: "headphone", playing: false, stale: true,
    recover: true,
    expect: { op: "applyRoute", to: "speaker" },
  },

  // ---------- 手动指定档位 ----------
  {
    name: "⑬【手动】指定有线耳机，当前绑扬声器 → 切耳机（即使有蓝牙也不抢）",
    outputs: [HEADPHONE, BLUETOOTH, SPEAKER], defaultDev: HEADPHONE,
    currentId: "speaker", playing: true, stale: false,
    outputMode: "headphone",
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "⑭【手动】已绑指定设备 → 保持不动（防自激）",
    outputs: [HEADPHONE, BLUETOOTH, SPEAKER], defaultDev: HEADPHONE,
    currentId: "headphone", playing: true, stale: false,
    outputMode: "headphone",
    expect: { op: "none" },
  },
  {
    name: "⑮【手动】指定扬声器（用户主动外放），有蓝牙也不抢",
    outputs: [HEADPHONE, BLUETOOTH, SPEAKER], defaultDev: HEADPHONE,
    currentId: "bt-a2dp", playing: true, stale: false,
    outputMode: "speaker",
    expect: { op: "applyRoute", to: "speaker" },
  },
  {
    name: "⑯【手动】指定设备被拔掉 → 不切，走 Auto 逻辑过渡（此处为扬声器稳态不动）",
    outputs: [SPEAKER], defaultDev: SPEAKER,
    currentId: "speaker", playing: true, stale: false,
    outputMode: "headphone",
    expect: { op: "none" },
  },
  {
    name: "⑰【手动】指定设备重新插上 → 自动切回",
    outputs: [HEADPHONE, SPEAKER], defaultDev: HEADPHONE,
    currentId: "speaker", playing: true, stale: false,
    outputMode: "headphone",
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "⑱【Auto】默认档位行为不变：有线+蓝牙 → 蓝牙优先",
    outputs: [HEADPHONE, BLUETOOTH, SPEAKER], defaultDev: HEADPHONE,
    currentId: "speaker", playing: true, stale: false,
    outputMode: "auto",
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },

  // ---------- BUG 回归：用户报的「拔耳机后点播放没声音」 ----------
  {
    name: "⑲【回归·用户报】Auto 档：扬声器播放 → 插耳机(走耳机) → 拔耳机(暂停) → 再点播放",
    outputs: [HDMI, SPEAKER], defaultDev: SPEAKER,     // 耳机已拔，列表只剩显示器 + 扬声器
    currentId: "headphone", playing: false, stale: true,
    recover: true, outputMode: "auto",
    expect: { op: "applyRoute", to: "speaker" },        // 必须回落扬声器，不是显示器、更不能不动
  },
  {
    name: "⑳【回归·对照】同上但被动刷新（拔耳机瞬间）→ 只暂停不回落",
    outputs: [HDMI, SPEAKER], defaultDev: SPEAKER,
    currentId: "headphone", playing: true, stale: false,
    outputMode: "auto",
    expect: { op: "pause+stale" },
  },
];

// recoverRoute 分支（用户点播放时）
// recoverRoute 分支（用户点播放时）：allowFallback = true
function recoverRoute(outputs, defaultDev, currentId, outputMode) {
  const target = resolveTarget(outputs, defaultDev, currentId, outputMode, true);
  if (!target) return { op: "clearStale" };
  return { op: "applyRoute", to: target.id };
}

let pass = 0, fail = 0;
console.log("============ 音频路由行为验证（蓝牙优先）============\n");

for (const s of S) {
  const got = s.recover
    ? recoverRoute(s.outputs, s.defaultDev, s.currentId, s.outputMode)
    : route(s.outputs, s.defaultDev, s.currentId, s.playing, s.stale, s.outputMode);

  // recoverRoute 的 clearStale 在期望里写作 none 的允许映射
  const norm = got.op === "clearStale" ? { op: "none" } : got;
  const ok = JSON.stringify(norm) === JSON.stringify(s.expect);

  console.log(`${ok ? "PASS" : "FAIL"}  ${s.name}`);
  if (!ok) {
    console.log(`      得到: ${JSON.stringify(norm)}`);
    console.log(`      期望: ${JSON.stringify(s.expect)}`);
  }
  ok ? pass++ : fail++;
}

console.log("\n================ 结果 ================");
console.log(`共 ${S.length} 组场景，通过 ${pass}，失败 ${fail}`);
console.log(fail === 0 ? "PASS" : "FAIL");
process.exit(fail === 0 ? 0 : 1);
