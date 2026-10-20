// 设备路由逻辑行为验证（蓝牙优先 + 平台差异）
// 复现 PlaybackEngine.qml 的 resolveTargetDevice + refreshAudioRoute 决策，
// 覆盖「有线 + 蓝牙同时连接」「蓝牙断开」「插拔有线」，以及
// **安卓 vs Windows 的平台差异**（2026-10-14 新增）。
//
// 跑法：node tools/verify_audio_route.js
//
// 平台差异的核心（源码依据见 Qt qtmultimedia/src/multimedia/android/）：
//   Windows：必须显式钉设备（audio.device = X 生效，不钉不跟随）
//   安卓  ：不能钉蓝牙 —— AudioPolicy 本就会自动路由到 A2DP；
//           且 A2DP 与 SCO 的 description 都是 "Bluetooth"，QML 无法区分，
//           选到 SCO 会被 AAudio 关流 → 完全没声音。
//           另外安卓的 isDefault 是「枚举列表第一个」，不是系统默认，不可信。

const SPEAKER = { id: "speaker", description: "Speaker (Realtek Audio)" };
const HEADPHONE = { id: "headphone", description: "Headphone (Realtek Audio)" };
const HDMI = { id: "hdmi", description: "VX2478-2 (Display Audio)" };
const BLUETOOTH = { id: "bt-a2dp", description: "Bluetooth A2DP Headphones" };

function isBluetooth(d) {
  const t = (d.description + " " + d.id).toLowerCase();
  return t.includes("bluetooth") || t.includes("a2dp");
}

// bluetoothDevice：安卓直接返回 null（蓝牙交给系统路由，我们不抢）
// bluetoothDevice：
//   Windows —— WASAPI 里 A2DP/SCO 不会同时出现，取第一个描述含 bluetooth 的
//   安卓    —— A2DP 与 SCO 的描述都是 "Bluetooth"，QML 无法区分，
//              所以按 C++ 助手给的 A2DP id 精确查找；没有 A2DP 返回 null
function bluetoothDevice(outputs, isAndroid, a2dpId) {
  if (isAndroid) {
    if (!a2dpId) return null;
    return outputs.find(x => x.id === a2dpId) || null;
  }
  return outputs.find(isBluetooth) || null;
}

// canPinDevice：是否允许把音频流钉到这台设备。
// 这个函数是**完备**的 —— 设备当前离线也返回 false（没什么可钉），调用方拿到非 null 才去钉
// 安卓上蓝牙只允许钉 A2DP：SCO 是 8kHz 通话通道，钉了会没声音
function canPinDevice(outputs, deviceId, isAndroid, a2dpId) {
  if (!deviceId || deviceId === "auto") return false;
  const d = outputs.find(x => x.id === deviceId);
  if (!d) return false;
  return isPinnableDevice(d, isAndroid, a2dpId);
}

// isPinnableDevice：平台策略层 —— 这台设备该不该钉（不含存在性判断）。
// 抽成单独函数是为了让 setOutputMode 与 resolveTargetDevice 用同一套判据
function isPinnableDevice(device, isAndroid, a2dpId) {
  if (!device) return false;
  if (!isAndroid) return true;
  if (!isBluetooth(device)) return true;   // 安卓：非蓝牙设备允许
  return device.id === a2dpId;             // 蓝牙里只认 A2DP
}

// 不变量：canPinDevice 不得比 isPinnableDevice 宽松 —— 它必须额外挡掉"设备当前离线"，
// 否则调用方会拿 null 去钉设备（曾经的 applyRoute(null) TypeError）
function checkPinnableConsistency(outputs, isAndroid, a2dpId) {
  for (const d of outputs) {
    const uiFlag = isPinnableDevice(d, isAndroid, a2dpId);
    const execFlag = canPinDevice(outputs, d.id, isAndroid, a2dpId);
    if (uiFlag !== execFlag)
      return `设备 ${d.id}：UI 判据=${uiFlag} 执行判据=${execFlag}`;
  }
  return null;
}

// resolveTargetDevice 的独立实现（带 allowFallback 与平台语义）
function resolveTarget(outputs, defaultDev, currentId, outputMode, allowFallback, isAndroid, a2dpId) {
  const curId = currentId;
  const bt = bluetoothDevice(outputs, isAndroid, a2dpId);
  const btId = bt ? bt.id : "";
  const defId = defaultDev && defaultDev.id ? defaultDev.id : "";
  const manualMode = outputMode && outputMode !== "auto";
  const alive = curId !== "" && outputs.some(d => d.id === curId);

  if (manualMode) {
    const wanted = outputs.find(d => d.id === outputMode) || null;
    // canPinDevice 同时挡住「设备不在线」和「当前平台不允许钉」
    if (wanted && canPinDevice(outputs, outputMode, isAndroid, a2dpId)) {
      if (wanted.id === curId) return null;
      return wanted;
    }
  }

  if (bt && btId !== curId) return bt;
  if (bt && btId === curId) return null;

  if (curId !== "" && !alive) {
    if (!allowFallback) return null;      // 被动刷新：不回落
  }

  // 安卓跳过「跟随系统默认」：defaultAudioOutput 会随设备列表刷新变化，
  // 用它做判断会误触发链路重建（2026-10-14 真机复现的卡顿）
  if (isAndroid) return null;

  if (defId === "") return null;
  if (curId === "" || curId !== defId) return defaultDev;
  return null;
}

function route(outputs, defaultDev, currentId, playing, stale, outputMode, isAndroid, a2dpId) {
  const curId = currentId;
  const alive = curId !== "" && outputs.some(d => d.id === curId);
  const bt = bluetoothDevice(outputs, isAndroid, a2dpId);
  const btId = bt ? bt.id : "";
  const defId = defaultDev && defaultDev.id ? defaultDev.id : "";
  const manualMode = outputMode && outputMode !== "auto";
  const wanted = manualMode ? outputs.find(d => d.id === outputMode) || null : null;

  // --- refreshAudioRoute 的快速返回（force=false） ---
  if (curId !== "" && alive && !stale) {
    const manualWants = manualMode && outputMode !== curId && wanted !== null
                        && canPinDevice(outputs, outputMode, isAndroid, a2dpId);
    const btWantsToTake = !manualMode && bt && btId !== curId;
    // 安卓不参与：defaultAudioOutput 会随设备列表刷新变化，用它判断会误触发重建
    const defChanged = !isAndroid && defId !== "" && curId !== defId;
    if (!manualWants && !btWantsToTake && !defChanged) return { op: "none" };
  }

  const target = resolveTarget(outputs, defaultDev, currentId, outputMode, false, isAndroid, a2dpId);
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

  // ---------- 平台差异：安卓（2026-10-14） ----------
  // 安卓上蓝牙与系统默认都不由我们钉，交给 AudioPolicy 自动路由
  {
    name: "㉑【安卓·用户报的 bug】蓝牙在线，Auto 档，当前绑扬声器 → 抢 A2DP",
    outputs: [SPEAKER, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "speaker", playing: true, stale: false,
    android: true,
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "㉒【安卓】当前已绑蓝牙 → 保持不动",
    outputs: [SPEAKER, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "bt-a2dp", playing: true, stale: false,
    android: true,
    expect: { op: "none" },
  },
  {
    name: "㉓【安卓·手动】指定蓝牙 A2DP → 允许钉（这正是修复目标）",
    outputs: [SPEAKER, BLUETOOTH, HEADPHONE], defaultDev: SPEAKER,
    currentId: "speaker", playing: true, stale: false,
    outputMode: "bt-a2dp", android: true,
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "㉔【安卓·手动】指定非蓝牙（有线耳机）→ 允许切换",
    outputs: [SPEAKER, BLUETOOTH, HEADPHONE], defaultDev: SPEAKER,
    currentId: "speaker", playing: true, stale: false,
    outputMode: "headphone", android: true,
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "㉕【安卓】插入有线耳机（默认设备变化）→ 不跟随（该值随列表刷新变化，不可用）",
    outputs: [HEADPHONE, SPEAKER], defaultDev: HEADPHONE,
    currentId: "speaker", playing: true, stale: false,
    android: true,
    expect: { op: "none" },
  },
  {
    name: "㉖【安卓】蓝牙断开（从列表消失），正在播放 → 暂停 + stale（不自动回落）",
    outputs: [SPEAKER], defaultDev: SPEAKER,
    currentId: "bt-a2dp", playing: true, stale: false,
    android: true,
    expect: { op: "pause+stale" },
  },
  {
    name: "㉗【安卓】蓝牙断开后用户点播放（recoverRoute）→ 不切换，保持档位",
    outputs: [SPEAKER], defaultDev: SPEAKER,
    currentId: "bt-a2dp", playing: false, stale: true,
    recover: true, android: true,
    expect: { op: "none" },
  },
  {
    name: "㉘【安卓】首启未绑定、A2DP 在线 → 直接钉 A2DP（Qt 默认设备不可信，必须主动钉）",
    outputs: [SPEAKER, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "", playing: false, stale: false,
    android: true,
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },

  // ---------- setOutputMode：档位切换 / 启动恢复 ----------
  // 重点是「设备当前离线」这条路径 —— 曾经在这里回归过
  {
    name: "㉙【Win·档位】档位是在线有线耳机 → 切过去",
    outputs: [SPEAKER, HEADPHONE, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "speaker", setMode: "headphone",
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "㉚【Win·档位·回归】档位设备当前离线 → 只能走 refreshRoute，绝不能 applyRoute(null)",
    outputs: [SPEAKER, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "speaker", setMode: "headphone",     // 耳机不在 outputs 里 = 当前离线
    expect: { op: "refreshRoute" },
  },
  {
    name: "㉛【Win·档位】切回 Auto → 走 refreshRoute 重新选路",
    outputs: [SPEAKER, HEADPHONE], defaultDev: SPEAKER,
    currentId: "headphone", setMode: "auto",
    expect: { op: "refreshRoute" },
  },
  {
    name: "㉜【Win·档位】档位是在线蓝牙 → Windows 上允许钉",
    outputs: [SPEAKER, HEADPHONE, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "speaker", setMode: "bt-a2dp",
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "㉝【安卓·档位】档位是在线 A2DP → 允许钉",
    outputs: [SPEAKER, HEADPHONE, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "speaker", setMode: "bt-a2dp", android: true,
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "㉞【安卓·档位】档位是在线非蓝牙（有线耳机）→ 允许钉",
    outputs: [SPEAKER, HEADPHONE, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "speaker", setMode: "headphone", android: true,
    expect: { op: "applyRoute", to: "headphone" },
  },
  {
    name: "㉟【安卓·档位】档位设备当前离线 → refreshRoute（同样不能 applyRoute(null)）",
    outputs: [SPEAKER, BLUETOOTH], defaultDev: SPEAKER,
    currentId: "speaker", setMode: "headphone", android: true,
    expect: { op: "refreshRoute" },
  },

  // ---------- 本次修复的核心：安卓显式钉 A2DP ----------
  // 真机实测：QAudioOutput 构造时就钉了 defaultAudioOutput()，
  // 而安卓的 defaultAudioOutput 是 getDevices() 枚举的第一个（本例中是 12672），
  // 不属于任何可用输出 → 界面在播放、完全没声音。所以必须主动钉 A2DP。
  {
    name: "㊱【安卓·真机回归】A2DP 在线，Auto 档，当前绑在错误设备(12672) → 必须抢 A2DP",
    outputs: [{ id: "12672", description: "Unknown device" }, SPEAKER, BLUETOOTH],
    defaultDev: SPEAKER,
    currentId: "12672", playing: true, stale: false,
    android: true, a2dpId: "bt-a2dp",
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
  {
    name: "㊲【安卓】A2DP 在线且当前已绑 A2DP → 保持不动（防自激）",
    outputs: [{ id: "12672", description: "Unknown device" }, SPEAKER, BLUETOOTH],
    defaultDev: SPEAKER,
    currentId: "bt-a2dp", playing: true, stale: false,
    android: true, a2dpId: "bt-a2dp",
    expect: { op: "none" },
  },
  {
    name: "㊳【安卓】蓝牙断开（没有 A2DP）→ 不钉任何设备，交给系统",
    outputs: [SPEAKER, { id: "bt-sco", description: "Bluetooth" }],
    defaultDev: SPEAKER,
    currentId: "speaker", playing: true, stale: false,
    android: true, a2dpId: "",
    expect: { op: "none" },
  },
  {
    name: "㊴【安卓·档位】手动指定 SCO → 挡住，走 refreshRoute（SCO 是通话通道，钉了没声音）",
    outputs: [SPEAKER, { id: "bt-a2dp", description: "Bluetooth" },
              { id: "bt-sco", description: "Bluetooth" }],
    defaultDev: SPEAKER,
    currentId: "speaker", setMode: "bt-sco", android: true, a2dpId: "bt-a2dp",
    expect: { op: "refreshRoute" },
  },
  {
    name: "㊵【安卓·真机回归】A2DP 在线，插了有线耳机 → 仍然抢 A2DP（用户要的是蓝牙出声）",
    outputs: [HEADPHONE, SPEAKER, BLUETOOTH], defaultDev: HEADPHONE,
    currentId: "headphone", playing: true, stale: false,
    android: true, a2dpId: "bt-a2dp",
    expect: { op: "applyRoute", to: "bt-a2dp" },
  },
];

// recoverRoute 分支（用户点播放时）
// setOutputMode：用户切换档位 / 启动时恢复档位。
// 曾经这里写成 if (canPinDevice(...)) applyRoute(findDeviceById(...))，
// 而 canPinDevice 在 Windows 上提前 return true 不查存在性，
// 设备离线时 findDeviceById 返回 null → applyRoute(null) 抛 TypeError。
// 所以 d 的存在性判断与 canPinDevice 缺一不可。
function setMode(outputs, currentId, deviceId, isAndroid, a2dpId) {
  const mode = (!deviceId || deviceId === "auto") ? "auto" : deviceId;
  const manualMode = mode !== "auto";
  if (manualMode) {
    const d = outputs.find(x => x.id === mode);
    if (d && canPinDevice(outputs, mode, isAndroid, a2dpId)) {
      return { op: "applyRoute", to: d.id };
    }
  }
  return { op: "refreshRoute" };
}

// recoverRoute 分支（用户点播放时）：allowFallback = true
function recoverRoute(outputs, defaultDev, currentId, outputMode, isAndroid, a2dpId) {
  const target = resolveTarget(outputs, defaultDev, currentId, outputMode, true, isAndroid, a2dpId);
  if (!target) return { op: "clearStale" };
  return { op: "applyRoute", to: target.id };
}

let pass = 0, fail = 0;
console.log("============ 音频路由行为验证（蓝牙优先 + 平台差异）============\n");

for (const s of S) {
  const isAndroid = s.android === true;
  // 未显式声明时，默认「蓝牙那条就是 A2DP」；声明为空串表示蓝牙没连
  const a2dpId = s.a2dpId !== undefined
      ? s.a2dpId
      : (isAndroid ? (s.outputs.find(isBluetooth) || {}).id || "" : "");
  let got;
  if (s.setMode) {
    got = setMode(s.outputs, s.currentId, s.setMode, isAndroid, a2dpId);
  } else if (s.recover) {
    got = recoverRoute(s.outputs, s.defaultDev, s.currentId, s.outputMode, isAndroid, a2dpId);
  } else {
    got = route(s.outputs, s.defaultDev, s.currentId, s.playing, s.stale, s.outputMode, isAndroid, a2dpId);
  }

  // recoverRoute 的 clearStale 在期望里写作 none 的允许映射
  const norm = got.op === "clearStale" ? { op: "none" } : got;
  // 不变量：执行判据必须比平台判据更严（见 checkPinnableConsistency）
  const drift = checkPinnableConsistency(s.outputs, isAndroid, a2dpId);
  const ok = JSON.stringify(norm) === JSON.stringify(s.expect) && !drift;

  console.log(`${ok ? "PASS" : "FAIL"}  ${s.name}`);
  if (!ok) {
    if (drift) console.log(`      判据分叉: ${drift}`);
    if (JSON.stringify(norm) !== JSON.stringify(s.expect)) {
      console.log(`      得到: ${JSON.stringify(norm)}`);
      console.log(`      期望: ${JSON.stringify(s.expect)}`);
    }
  }
  ok ? pass++ : fail++;
}

console.log("\n================ 结果 ================");
const androidN = S.filter(s => s.android).length;
console.log(`共 ${S.length} 组场景（含安卓 ${androidN} 组），通过 ${pass}，失败 ${fail}`);
console.log(fail === 0 ? "PASS" : "FAIL");
process.exit(fail === 0 ? 0 : 1);
