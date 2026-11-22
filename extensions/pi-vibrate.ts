/**
 * pi-vibrate —— 把「pi 停工等待输入」变成手环振动
 *
 * 链路：pi agent_settled ──HTTP──▶ 本机 ntfy ──局域网──▶ 手机 ntfy App
 *       ──▶ 华为运动健康同步状态栏通知 ──▶ 手环振动
 *
 * 配置：~/.config/band-notify/config.json（install.sh 生成）；环境变量可覆盖：
 *   BAND_NOTIFY_SERVER / PI_VIBRATE_SERVER   默认 http://127.0.0.1:2586
 *   BAND_NOTIFY_TOPIC  / PI_VIBRATE_TOPIC    ntfy topic（必填，install.sh 会生成随机值）
 *   PI_VIBRATE_MIN_MS                        运行时长低于该值不提醒（默认 10000ms，0 = 全部提醒）
 *   PI_VIBRATE_CONFIRM_MS                    手机不在线时的重试总时长（默认 180000ms = 3 分钟）
 *   PI_VIBRATE_RETRY_MS                      重试间隔（默认 15000ms）
 *   BAND_NOTIFY_REPO  / PI_VIBRATE_REPO      本仓库路径（用于自动刷新订阅页）
 *   PI_VIBRATE_DISABLE=1                     临时关闭全部提醒
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir, networkInterfaces } from "node:os";
import { basename, join } from "node:path";

type FileConfig = {
  server?: string;
  topic?: string;
  minRunMs?: number;
  confirmMs?: number;
  retryMs?: number;
  repoDir?: string;
  lanInterface?: string;
};

function readConfigFile(): FileConfig {
  const dir = process.env.BAND_NOTIFY_CONFIG_DIR
    ?? join(process.env.XDG_CONFIG_HOME ?? join(homedir(), ".config"), "band-notify");
  try {
    return JSON.parse(readFileSync(join(dir, "config.json"), "utf8")) as FileConfig;
  } catch {
    return {};
  }
}

function num(value: unknown, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

const FILE_CFG = readConfigFile();
const SERVER = process.env.BAND_NOTIFY_SERVER ?? process.env.PI_VIBRATE_SERVER ?? FILE_CFG.server ?? "http://127.0.0.1:2586";
const TOPIC = process.env.BAND_NOTIFY_TOPIC ?? process.env.PI_VIBRATE_TOPIC ?? FILE_CFG.topic ?? "";
const MIN_RUN_MS = num(process.env.PI_VIBRATE_MIN_MS ?? FILE_CFG.minRunMs, 10000);
const CONFIRM_MS = num(process.env.PI_VIBRATE_CONFIRM_MS ?? FILE_CFG.confirmMs, 180000);
const RETRY_MS = num(process.env.PI_VIBRATE_RETRY_MS ?? FILE_CFG.retryMs, 15000);
const REPO_DIR = process.env.BAND_NOTIFY_REPO ?? process.env.PI_VIBRATE_REPO ?? FILE_CFG.repoDir ?? "";
const LAN_IFACE = process.env.BAND_NOTIFY_IFACE ?? FILE_CFG.lanInterface ?? "wlan0";
const INCLUDE_PROJECT = process.env.BAND_NOTIFY_INCLUDE_PROJECT !== "0";
const TIMEOUT_MS = 3000;
const COOLDOWN_MS = 5000;
const PORT = (() => {
  try { return new URL(SERVER).port || "2586"; } catch { return "2586"; }
})();

let runStartedAt = 0;
let lastSentAt = 0;
let warned = false;
let runEpoch = 0;
let delivering = false;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function post(title: string, message: string, priority: number, tags: string[]) {
  if (!TOPIC) return false;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(SERVER, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ topic: TOPIC, title, message, priority, tags }),
      signal: ctrl.signal,
    });
    // 消费掉 body，避免 undici 连接无法归还连接池。
    await res.arrayBuffer().catch(() => undefined);
    return res.ok;
  } catch {
    return false; // ntfy 没起 / 不在局域网：静默失败，绝不打断 pi
  } finally {
    clearTimeout(timer);
  }
}

/** 手机端（ntfy App）现在是否真的连着我们？（比 subscribers 计数更准）
 *  判断依据：本机 ntfy 端口上是否存在一条来自“别的设备”的已建立 TCP 连接 */
async function phoneOnlineViaSocket(pi: ExtensionAPI): Promise<boolean | null> {
  try {
    const r = await pi.exec("ss", ["-Htn", "state", "established", `( sport = :${PORT} )`], { timeout: 3000 });
    if (r.code !== 0) return null;
    const ipOf = (s: string) => (s || "").replace(/^\[|\]$/g, "").replace(/^::ffff:/, "").replace(/:\d+$/, "");
    const lines = (r.stdout || "").split("\n").map((l) => l.trim()).filter(Boolean);
    const fields = lines.map((l) => l.split(/\s+/));
    const localIps = new Set(fields.map((f) => ipOf(f[2])));
    for (const f of fields) {
      const peer = ipOf(f[3]);
      if (!peer) continue;
      if (peer === "127.0.0.1" || peer === "::1") continue;
      if (localIps.has(peer)) continue; // 本机自连（例如自己 curl 一下）
      return true;                      // 有外部设备连着（通常就是手机）
    }
    return false;
  } catch {
    return null;
  }
}

/** 兜底：读 ntfy 的订阅者计数 */
async function phoneOnlineViaMetrics(): Promise<boolean> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(new URL("/metrics", SERVER), { signal: ctrl.signal });
    const text = await res.text().catch(() => "");
    if (!res.ok) return false;
    const m = text.match(/^ntfy_subscribers_total\s+(\d+)/m);
    return m ? Number(m[1]) > 0 : false;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

/** 发布 + 送达保障：手机不在线时按 retryMs 重发，最长 confirmMs，直到确认手机在线。
 *  新一回合开始（runEpoch 变化）会立即取消旧的重试链，避免上一轮的提醒一直追着震。 */
async function deliver(pi: ExtensionAPI, title: string, message: string, priority: number, tags: string[]) {
  if (!TOPIC || process.env.PI_VIBRATE_DISABLE === "1") return;
  const now = Date.now();
  if (now - lastSentAt < COOLDOWN_MS) return;
  lastSentAt = now;

  const epoch = runEpoch;
  await post(title, message, priority, tags);
  if (await isPhoneOnline(pi)) return;

  // 同一时间只跑一条重试链；新的提醒会在下次 agent_settled 时再发。
  if (delivering) return;
  delivering = true;
  try {
    const deadline = Date.now() + CONFIRM_MS;
    while (Date.now() < deadline) {
      await sleep(RETRY_MS);
      if (epoch !== runEpoch) return;
      await post(title, message, priority, tags);
      if (await isPhoneOnline(pi)) return;
    }
  } finally {
    delivering = false;
  }
}

/** 本机当前局域网 IPv4（优先配置的网卡，否则第一个非回环地址）。 */
function localIp(): string {
  const nets = networkInterfaces();
  const names = [LAN_IFACE, ...Object.keys(nets)];
  for (const name of names) {
    for (const net of nets[name] ?? []) {
      if (net.family === "IPv4" && !net.internal) return net.address;
    }
  }
  return "";
}

/** 链路体检：手机没连上时（多半是热点换了网段、手机里的订阅地址失效），
 *  自动刷新订阅二维码并在 pi 界面提示 —— 避免“静默失效，直到你发现手环不震”。 */
async function healthCheck(pi: ExtensionAPI, ctx: { ui?: { notify?: (m: string, level?: string) => void } }) {
  let ok = false;
  try { ok = await isPhoneOnline(pi); } catch { return; }
  if (ok) {
    if (warned) { warned = false; ctx.ui?.notify?.("✅ 手环提醒已恢复连接", "info"); }
    return;
  }
  if (warned) return;
  warned = true;

  const ip = localIp();
  if (REPO_DIR) {
    try {
      // 用参数传目录，避免路径里出现空格/引号时拼 shell 字符串。
      await pi.exec("bash", ["-c", 'cd "$1" && ./scripts/make-subscribe.sh', "bash", REPO_DIR], { timeout: 10000 });
    } catch {}
  }
  const hint = REPO_DIR
    ? `运行 ${REPO_DIR}/scripts/make-subscribe.sh，打开生成的 subscribe.html 重新扫码`
    : "运行 band-notify-subscribe 重新生成订阅页，再用手机扫码";
  ctx.ui?.notify?.(
    `⚠️ 手环提醒未连接：手机里订阅的地址可能已失效（本机现在是 ${ip || "<LAN_IP>"}:${PORT}，热点重启会换网段）。\n` +
    `解决办法：${hint}。`,
    "warning",
  );
}

/** 合并判断：socket 优先，metrics 兜底 */
async function isPhoneOnline(pi: ExtensionAPI): Promise<boolean> {
  const viaSocket = await phoneOnlineViaSocket(pi);
  return viaSocket === null ? await phoneOnlineViaMetrics() : viaSocket;
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", async (_event, ctx) => {
    runEpoch += 1;
    void healthCheck(pi, ctx);
  });

  pi.on("agent_start", async (_event, ctx) => {
    runEpoch += 1;
    runStartedAt = Date.now();
    void healthCheck(pi, ctx);
  });

  // agent_settled = pi 不会再自动继续（agent_end 之后还可能重试/续跑）
  pi.on("agent_settled", async (_event, ctx) => {
    if (ctx.isIdle && !ctx.isIdle()) return;            // 别的扩展又起了新 run
    if (Date.now() - runStartedAt < MIN_RUN_MS) return; // 秒回的小交互不打扰
    const project = basename(ctx.cwd || "") || "pi";
    const label = INCLUDE_PROJECT ? `${project} · ` : "";
    void deliver(pi, "pi 停工等你", `${label}任务结束，等你回来看结果`, 5, ["robot"]);
  });

  // pi 弹窗等你选择/确认时
  pi.on("ui_prompt_start", async (event) => {
    void deliver(pi, "pi 需要你操作", `正在等你${event.kind}确认`, 4, ["warning"]);
  });
}
