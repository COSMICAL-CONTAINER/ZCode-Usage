#!/usr/bin/env node
/**
 * quota-guard:额度阈值守卫 hook(零依赖,Node >= 18)
 *
 * 数据源:~/.zcode/scripts/usage-state.json(由 zcode-usage.mjs 的 --hook / --state 写盘,
 * Windows 悬浮窗每次刷新也会带 --state)。本脚本只读本地文件、不发网络请求——
 * ZCode hook 是 inline 执行的,必须毫秒级返回。
 *
 * 事件(--event):
 *   UserPromptSubmit  任一池 ≥ 阈值时注入一行警告上下文(warnIntervalMinutes 内不重复),否则静默
 *   Stop              超阈值且未布置续跑 → {"continue":true,"reason":"<收尾协议>"} 拦住会话;
 *                     resume-armed.flag 记录的 armedForResetAt ≥ 绑定池重置时间 → 视为已布置,放行。
 *                     重置周期翻篇后 flag 自动过期,新周期重新拦截。
 *
 * 输出为 ZCode hook 严格 schema(多余字段会被丢弃),一切正常时静默 exit 0;
 * 本脚本永远不用 exit 2(不阻塞工具)。
 * 可选配置 ~/.zcode/scripts/quota-guard-settings.json:{ "threshold": 95, "warnIntervalMinutes": 10 }
 *
 * 测试参数:--dir 可把 state/flag/warn/settings 全部重定向到临时目录(供 node --test 使用)。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const argv = process.argv.slice(2);
const argValue = (name) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
};
const event = argValue('--event') || 'UserPromptSubmit';

const dir = argValue('--dir') || path.join(os.homedir(), '.zcode', 'scripts');
const stateFile = argValue('--state-file') || path.join(dir, 'usage-state.json');
const flagFile = argValue('--flag-file') || path.join(dir, 'resume-armed.flag');
const warnFile = argValue('--warn-file') || path.join(dir, 'quota-guard-warn.json');
const settingsFile = argValue('--settings-file') || path.join(dir, 'quota-guard-settings.json');

// 排干 stdin(hook runner 会写事件负载,不消费可能让写方阻塞),unref 使其不拖住进程退出
try { process.stdin.resume(); process.stdin.unref(); } catch { }

const DEFAULT_THRESHOLD = 95;
const DEFAULT_WARN_INTERVAL_MIN = 10;
const STATE_MAX_AGE_MS = 30 * 60_000; // 快照过期(widget 停了且长时间无新会话)时不打扰

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  } catch { return null; }
}

function loadSettings() {
  const s = readJson(settingsFile) || {};
  const threshold = Number(s.threshold);
  const warnMin = Number(s.warnIntervalMinutes);
  return {
    threshold: threshold > 0 && threshold < 100 ? threshold : DEFAULT_THRESHOLD,
    warnIntervalMinutes: warnMin > 0 ? warnMin : DEFAULT_WARN_INTERVAL_MIN,
  };
}

function fmtCountdown(ms) {
  const min = Math.max(0, Math.round(ms / 60000));
  const d = Math.floor(min / 1440);
  const h = Math.floor((min % 1440) / 60);
  const m = min % 60;
  const parts = [];
  if (d) parts.push(`${d} 天`);
  if (h) parts.push(`${h} 小时`);
  if (m || parts.length === 0) parts.push(`${m} 分钟`);
  return parts.join(' ');
}

const fmtResetLocal = (ms) => (ms > 0
  ? new Date(ms).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' })
  : '未知');

// 调用日志:每次触发都留痕(hook 是静默设计,没有它无法定位"为什么没拦")
function debugLog(msg) {
  try {
    fs.appendFileSync(path.join(dir, 'quota-guard.log'),
      `${new Date().toISOString()} [${event}] ${msg}\n`);
  } catch { }
}

function main() {
  const { threshold, warnIntervalMinutes } = loadSettings();
  const state = readJson(stateFile);
  if (!state || !Array.isArray(state.pools)) { debugLog('pass: 无快照'); return; }
  const ageSec = Math.round((Date.now() - Number(state.updatedAt || 0)) / 1000);
  if (Date.now() - Number(state.updatedAt || 0) > STATE_MAX_AGE_MS) { debugLog(`pass: 快照过期 ${ageSec}s`); return; }

  const over = state.pools.filter((p) => Number(p.usedPct) >= threshold);
  if (!over.length) {
    debugLog(`pass: 未超阈值(各池 ${state.pools.map((p) => `${p.key}:${Number(p.usedPct).toFixed(0)}%`).join(' ')} < ${threshold}%)`);
    return;
  }
  debugLog(`hit: ${over.map((p) => `${p.key}:${Number(p.usedPct).toFixed(0)}%`)} ≥ ${threshold}%(快照 ${ageSec}s 前)`);

  // 绑定约束:超阈值池中重置时间最晚者——每周额度耗尽时,5 小时池重置了也没用
  const binding = over.reduce((a, b) => ((Number(b.resetAt) || 0) > (Number(a.resetAt) || 0) ? b : a));
  const bindingReset = Number(binding.resetAt) || 0;
  const poolList = over.map((p) => `${p.label || p.key} ${Number(p.usedPct).toFixed(0)}%`).join('、');

  if (event === 'Stop') {
    const flag = readJson(flagFile);
    if (bindingReset > 0 && flag && Number(flag.armedForResetAt) >= bindingReset) { debugLog('pass: flag 已布置,放行'); return; }
    // Stop 的拦截必须走 decision:"block"(ZCode 源码对 Stop 的 block 路径:
    // blockRequested=true + reason 反馈给模型强制续跑);continue:true 实测不生效
    debugLog('拦截 → 输出 decision:block 收尾协议');
    const reason = [
      `额度警报:${poolList} 已达阈值 ${threshold}%(约 ${fmtResetLocal(bindingReset)} 重置)。不要继续任务主体,立即执行收尾协议:`,
      `1. 把当前任务状态写入 ~/.zcode/quota-handoff.md:任务目标、已完成进度、下一步计划、恢复所需的全部上下文;`,
      `2. 用 CronCreate 布置一次性自动化(${fmtResetLocal(bindingReset)} 后 5 分钟触发,recurring=false、maxRuns=1),prompt 必须要求:先读 ~/.zcode/quota-handoff.md,再运行 node ~/.zcode/scripts/zcode-usage.mjs 复查额度(低于阈值才继续),然后接着执行任务;`,
      `3. 向 ~/.zcode/scripts/resume-armed.flag 写入 {"armedForResetAt": ${bindingReset}} 标记已布置(之后 Stop 检查会放行);`,
      `4. 完成后正常结束本次回复,不要再发起新的大型工作。`,
    ].join('\n');
    console.log(JSON.stringify({ decision: 'block', reason }));
    return;
  }

  // UserPromptSubmit:节流告警
  const now = Date.now();
  const last = readJson(warnFile);
  if (last && now - Number(last.at || 0) < warnIntervalMinutes * 60_000) { debugLog('pass: 告警节流窗口内'); return; }
  try { fs.writeFileSync(warnFile, JSON.stringify({ at: now, pools: over.map((p) => p.key) })); } catch { }
  const line = `【额度警报】${poolList} 已达阈值 ${threshold}%,` +
    `${bindingReset > now ? fmtCountdown(bindingReset - now) : '即将'}后重置。` +
    `新开长任务前先斟酌;若准备收尾,请按 quota-guard 协议布置续跑。`;
  console.log(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: line },
  }));
}

main();
