/**
 * dsh-band-notify —— DSH（DeepSeek Harness）宿主插件：
 * 把「回合结束 / 等你确认 / 等你回答 / 因错停止」推给本机 ntfy，
 * 再由手机 ntfy → 华为运动健康 → 华为手环 10 振动。
 *
 * 与项目里其它 harness 的钩子（band-notify-hook、pi-vibrate、zcode 闸门）共用
 * 同一个 ntfy 服务与 topic，所以只需要在 DSH profile 里挂这一个插件。
 *
 * 设计要点：
 * · 只订阅 `session/event`，不依赖任何宿主服务（inject 为空），加载失败不影响 DSH。
 * · 子会话（subagent / teammate，header.origin === 'subagent' 或 delegationDepth > 0）不提醒，
 *   否则一条主任务会震很多次。
 * · `turn/end` 之后不立刻发：等 settleMs（默认 5s），期间若新回合开始（排队消息、
 *   goal 续跑、cron、teammate 回信）就取消；这样避免「回合结束了但马上又接着干」的误报。
 * · `approval/asked`、`ask_user_question` 工具调用是「真的在等你」，立即提醒。
 * · 同一会话 cooldownMs（默认 20s）内只提醒一次；网络请求 2s 超时、永不抛错。
 * · 所有动作写日志到 ~/.local/state/band-notify/dsh-band-notify.log，便于排查。
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir, networkInterfaces } from 'node:os'
import { basename, dirname } from 'node:path'

export const name = 'dsh-band-notify'

/** 不依赖任何宿主服务：纯事件订阅 + fetch。 */
export const inject = []

const VERSION = '0.2.1'
const HARNESS = 'dsh'

const DEFAULTS = {
  /** ntfy 服务地址；一律走本机回环，避免换网段后失效。 */
  server: 'http://127.0.0.1:2586',
  /** ntfy topic（topic 本身就是密码）；空 = 插件不发送，等用户配置。 */
  topic: '',
  /** 优先探测的局域网网卡；用于发现「订阅页 IP 与本机 IP 不一致」。 */
  lanInterface: 'wlan0',
  /** turn/end 之后等多久确认「真的停工了」。 */
  settleMs: 5000,
  /** 额外的安静期：最近这么多毫秒内还有会话事件就不发（0 = 只靠 settleMs）。 */
  quietMs: 0,
  /** 同一会话两次提醒的最小间隔。 */
  cooldownMs: 20000,
  /** 多久查一次手机端订阅状态（0 = 不查）。用于日志里记录掉线/恢复。 */
  watchdogMs: 30000,
  /** HTTP 超时。 */
  timeoutMs: 2000,
  notifyOnTurnEnd: true,
  notifyOnError: true,
  notifyOnApproval: true,
  notifyOnQuestion: true,
  /** 空数组 = 所有项目都提醒；填项目目录名（如 ["my-project"]）可只看某些项目。 */
  projects: [],
  /** 通知正文是否带项目目录名；共享局域网里建议设为 false。 */
  includeProjectName: true,
  /** true 时只写日志不真的推送，用于调试。 */
  dryRun: false,
  /** 状态目录；日志/自检标记/订阅页默认都放在这里。 */
  stateDir: '~/.local/state/band-notify',
  /** 留空则用 ${stateDir}/dsh-band-notify.log。 */
  logFile: '',
  maxLogBytes: 512 * 1024,
  /** 视为「在等你回答」的工具名。 */
  questionTools: ['ask_user_question'],
  /** 这些 origin 的会话不提醒（teammate 也属于子会话）。 */
  skipOrigins: ['subagent', 'teammate'],
  /** 自检标记：留空则用 ${stateDir}/dsh-band-notify.selftest。 */
  selftestMarker: '',
  /** subscribe.html 路径；留空则用 ${stateDir}/subscribe.html。 */
  subscribePage: '',
}

function expandHome(path) {
  if (typeof path !== 'string' || path === '') return path
  if (path === '~') return homedir()
  if (path.startsWith('~/')) return homedir() + path.slice(1)
  return path
}

function rotateLog(file, maxBytes) {
  try {
    if (statSync(file).size <= maxBytes) return
    writeFileSync(file, '')
  } catch {
    /* 文件不存在或不可读，忽略 */
  }
}

/** 读取 install.sh 生成的共享配置；DSH 的显式配置优先。 */
function readConfigFile() {
  const dir = process.env.BAND_NOTIFY_CONFIG_DIR
    ?? `${process.env.XDG_CONFIG_HOME || `${homedir()}/.config`}/band-notify`
  try {
    return JSON.parse(readFileSync(`${dir}/config.json`, 'utf8'))
  } catch {
    return {}
  }
}

/** 环境变量覆盖（与 shell/Python/pi 的优先级保持一致）。 */
function readEnvConfig() {
  const env = {}
  if (process.env.BAND_NOTIFY_SERVER) env.server = process.env.BAND_NOTIFY_SERVER
  if (process.env.BAND_NOTIFY_TOPIC) env.topic = process.env.BAND_NOTIFY_TOPIC
  if (process.env.BAND_NOTIFY_IFACE) env.lanInterface = process.env.BAND_NOTIFY_IFACE
  if (process.env.BAND_NOTIFY_STATE_DIR) env.stateDir = process.env.BAND_NOTIFY_STATE_DIR
  if (process.env.BAND_NOTIFY_SUBSCRIBE_PAGE) env.subscribePage = process.env.BAND_NOTIFY_SUBSCRIBE_PAGE
  return env
}

export function apply(ctx, config) {
  const cfg = { ...DEFAULTS, ...readConfigFile(), ...readEnvConfig(), ...(config ?? {}) }
  const stateDir = expandHome(cfg.stateDir || '~/.local/state/band-notify')
  cfg.logFile = expandHome(cfg.logFile || `${stateDir}/dsh-band-notify.log`)
  cfg.selftestMarker = expandHome(cfg.selftestMarker || `${stateDir}/dsh-band-notify.selftest`)
  cfg.subscribePage = expandHome(cfg.subscribePage || `${stateDir}/subscribe.html`)
  if (process.env.BAND_NOTIFY_INCLUDE_PROJECT === '0') cfg.includeProjectName = false
  const logFile = cfg.logFile

  const log = (line) => {
    try {
      mkdirSync(dirname(logFile), { recursive: true })
      rotateLog(logFile, cfg.maxLogBytes)
      appendFileSync(logFile, `${new Date().toISOString()} ${line}\n`)
    } catch {
      /* 日志失败不影响提醒 */
    }
  }

  if (typeof cfg.topic !== 'string' || cfg.topic.length === 0) {
    log('disabled: no topic configured; set topic in DSH config or ~/.config/band-notify/config.json')
    return
  }

  /** sessionId -> 该会话的提醒状态 */
  const sessions = new Map()

  /** 手机端 ntfy 的订阅数（undefined = 还没查到）。0 表示消息只会进缓存，手环不会振。 */
  let subscribers
  let watchdogTimer

  const readSubscribers = async () => {
    try {
      const response = await fetch(`${cfg.server}/metrics`, { signal: AbortSignal.timeout(cfg.timeoutMs) })
      if (!response.ok) return undefined
      const text = await response.text()
      const match = /^ntfy_subscribers_total\s+(\d+)\s*$/m.exec(text)
      return match === null ? undefined : Number(match[1])
    } catch {
      return undefined
    }
  }

  /** 本机当前局域网 IPv4（优先配置的网卡）。 */
  const currentLanIp = () => {
    const nets = networkInterfaces()
    for (const name of [cfg.lanInterface || 'wlan0', ...Object.keys(nets)]) {
      for (const net of nets[name] ?? []) {
        if (net.family === 'IPv4' && !net.internal) return net.address
      }
    }
    return undefined
  }

  /** subscribe.html 里的订阅 IP 与本机当前 IP 不一致 → 手机订的是旧地址（换网段了），记一笔。 */
  let lastNetworkWarn = ''
  const checkNetworkChange = () => {
    if (typeof cfg.subscribePage !== 'string' || cfg.subscribePage === '') return
    let page
    try {
      page = readFileSync(expandHome(cfg.subscribePage), 'utf8')
    } catch {
      return
    }
    const match = /ntfy:\/\/([\d.]+):\d+\//.exec(page)
    if (match === null) return
    const ip = currentLanIp()
    if (ip === undefined || ip === match[1]) return
    const key = `${match[1]}->${ip}`
    if (lastNetworkWarn === key) return
    lastNetworkWarn = key
    log('network changed: subscribe.html 里的 IP 与本机当前 LAN IP 不一致 — 需要重新运行 band-notify-subscribe 并重新扫码')
  }

  const checkSubscribers = async () => {
    const now = await readSubscribers()
    if (now === 0) checkNetworkChange()
    if (now === undefined || now === subscribers) return
    const previous = subscribers
    subscribers = now
    if (now > 0) log(`phone online (subscribers=${now})${previous === 0 ? ' — 手机端重新连上了' : ''}`)
    else log('phone offline (subscribers=0) — 这期间的通知只进 ntfy 缓存，手环不会振')
  }

  const rawProjectName = (session) => {
    const cwd = session?.header?.cwd
    if (typeof cwd === 'string' && cwd.length > 0) {
      const name = basename(cwd.replace(/\/+$/, ''))
      if (name.length > 0) return name
    }
    return HARNESS
  }

  const projectName = (session) => (cfg.includeProjectName ? rawProjectName(session) : '')

  const isUserFacing = (session) => {
    if (session === null || typeof session !== 'object') return false
    if (typeof session.id !== 'string' || session.id.length === 0) return false
    const header = session.header ?? {}
    const origin = typeof header.origin === 'string' ? header.origin.toLowerCase() : ''
    if (Array.isArray(cfg.skipOrigins) && origin !== '' && cfg.skipOrigins.includes(origin)) return false
    if (typeof header.delegationDepth === 'number' && header.delegationDepth > 0) return false
    return true
  }

  const stateOf = (session) => {
    let state = sessions.get(session.id)
    if (state === undefined) {
      state = {
        session,
        lastEventAt: Date.now(),
        lastNotifyAt: 0,
        awaiting: undefined,
        currentTurnId: undefined,
        lastFinishedTurnId: undefined,
        timer: undefined,
      }
      sessions.set(session.id, state)
      if (sessions.size > 500) {
        for (const [id, old] of sessions) {
          if (id === session.id) continue
          if (old.timer !== undefined) continue
          sessions.delete(id)
          if (sessions.size <= 400) break
        }
      }
    }
    return state
  }

  const clearTimer = (state) => {
    if (state.timer !== undefined) {
      clearTimeout(state.timer)
      state.timer = undefined
    }
  }

  const label = (proj) => (proj ? `${proj} · ` : '')

  const render = (kind, proj, extra = {}) => {
    switch (kind) {
      case 'approval':
        return {
          title: `${HARNESS} 需要你确认`,
          message: `${label(proj)}${extra.tool || '工具调用'} 等你点允许/确认`,
          priority: 5,
          tags: ['warning'],
        }
      case 'question':
        return {
          title: `${HARNESS} 在等你回答`,
          message: `${label(proj)}有个问题等你回答`,
          priority: 5,
          tags: ['question'],
        }
      case 'error':
        return {
          title: `${HARNESS} 因错误停止`,
          message: `${label(proj)}出错中断了，来看一眼`,
          priority: 5,
          tags: ['rotating_light'],
        }
      case 'test':
        return {
          title: `${HARNESS} 手环提醒已接入`,
          message: `${label(proj)}插件已加载，这是一条自检通知`,
          priority: 5,
          tags: ['white_check_mark'],
        }
      case 'idle':
      default:
        return {
          title: `${HARNESS} 停工等你`,
          message: `${label(proj)}任务结束，等你回来看结果`,
          priority: 5,
          tags: ['robot'],
        }
    }
  }

  const send = async (payload, why) => {
    if (cfg.dryRun) {
      const safe = { ...payload, topic: payload.topic ? 'set' : 'missing' }
      log(`dryRun ${why} ${JSON.stringify(safe)}`)
      return true
    }
    try {
      const [response, subs] = await Promise.all([
        fetch(cfg.server, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
          signal: AbortSignal.timeout(cfg.timeoutMs),
        }),
        readSubscribers(),
      ])
      // 消费掉 body，避免 undici 连接无法归还连接池。
      await response.text().catch(() => '')
      const detail =
        subs === undefined ? '' : subs === 0 ? ' subs=0 (手机不在线，只进缓存)' : ` subs=${subs}`
      log(`sent ${why} http=${response.status}${response.ok ? '' : ' (failed)'}${detail}`)
      return response.ok
    } catch (error) {
      log(`send failed ${why}: ${error?.message || String(error)}`)
      return false
    }
  }

  const notify = (state, kind, extra) => {
    const now = Date.now()
    const since = now - state.lastNotifyAt
    if (since < cfg.cooldownMs) {
      log(`suppress ${kind} ${projectName(state.session)} (cooldown ${since}ms)`)
      return
    }
    state.lastNotifyAt = now
    const proj = projectName(state.session)
    const payload = { topic: cfg.topic, ...render(kind, proj, extra) }
    void send(payload, `${kind}/${proj || 'project'}`).then((ok) => {
      // 发送失败时把冷却时间清掉，让下一次审批/提问还能提醒。
      if (!ok) state.lastNotifyAt = 0
    })
  }

  const settle = (state) => {
    if (state.awaiting === undefined) return
    const quiet = cfg.quietMs - (Date.now() - state.lastEventAt)
    if (quiet > 0) {
      schedule(state, quiet)
      return
    }
    const kind = state.awaiting
    state.awaiting = undefined
    notify(state, kind === 'error' ? 'error' : 'idle')
  }

  const schedule = (state, delay) => {
    clearTimer(state)
    const timer = setTimeout(() => {
      state.timer = undefined
      try {
        settle(state)
      } catch (error) {
        log(`settle error: ${error?.stack || String(error)}`)
      }
    }, Math.max(0, delay))
    timer.unref?.()
    state.timer = timer
  }

  const onTurnEnd = (state, event) => {
    const kind = event?.data?.reason?.kind
    const turn = event?.data?.turn
    if (kind === 'completed' || kind === 'max-tokens') {
      if (!cfg.notifyOnTurnEnd) return
      state.awaiting = 'idle'
      schedule(state, cfg.settleMs)
      return
    }
    if (kind === 'error') {
      if (!cfg.notifyOnError) return
      state.awaiting = 'error'
      schedule(state, Math.min(cfg.settleMs, 2000))
      return
    }
    // aborted（用户中断 / 父会话取消）、blocked、forked、interrupted、未知：不提醒
    state.awaiting = undefined
    clearTimer(state)
    log(`skip turn/end ${projectName(state.session)} turn=${turn} kind=${kind ?? 'unknown'}`)
  }

  const onEvent = (session, event) => {
    const type = event?.type
    if (typeof type !== 'string') return
    if (!isUserFacing(session)) return
    const filterProj = rawProjectName(session)
    if (Array.isArray(cfg.projects) && cfg.projects.length > 0 && !cfg.projects.includes(filterProj)) return

    const state = stateOf(session)
    state.lastEventAt = Date.now()

    switch (type) {
      case 'turn/start':
        state.currentTurnId = event?.data?.turn
        if (state.lastFinishedTurnId === state.currentTurnId) state.lastFinishedTurnId = undefined
        state.awaiting = undefined
        clearTimer(state)
        return
      case 'turn/end': {
        const turn = event?.data?.turn
        // 宿主补发/重放上一回合的 turn/end 时不要在新回合里误报。
        if (turn !== undefined && state.currentTurnId !== undefined && turn !== state.currentTurnId) {
          log(`skip stale turn/end ${projectName(session)} turn=${turn} current=${state.currentTurnId}`)
          return
        }
        // 同一回合的 turn/end 被重复投递时也不要再发一次。
        if (turn !== undefined && state.lastFinishedTurnId === turn) {
          log(`skip duplicate turn/end ${projectName(session)} turn=${turn}`)
          return
        }
        if (turn !== undefined) state.lastFinishedTurnId = turn
        onTurnEnd(state, event)
        return
      }
      case 'approval/asked':
        if (cfg.notifyOnApproval) notify(state, 'approval', { tool: event?.data?.toolName })
        return
      case 'tool/call': {
        const tool = event?.data?.name
        if (cfg.notifyOnQuestion && Array.isArray(cfg.questionTools) && cfg.questionTools.includes(tool)) {
          notify(state, 'question', { tool })
        }
        return
      }
      default:
        return
    }
  }

  const handler = (session, event) => {
    try {
      onEvent(session, event)
    } catch (error) {
      log(`handler error: ${error?.stack || String(error)}`)
    }
  }

  ctx.on('session/event', handler)

  try {
    ctx.effect(() => () => {
      for (const state of sessions.values()) clearTimer(state)
      sessions.clear()
      if (watchdogTimer !== undefined) {
        clearInterval(watchdogTimer)
        watchdogTimer = undefined
      }
      log(`disposed v${VERSION}`)
    }, `${name}: timers`)
  } catch {
    /* 老版本 cordis 没有 effect 时忽略清理 */
  }

  log(`loaded v${VERSION} server=${cfg.server} topic=${cfg.topic ? 'set' : 'missing'} settleMs=${cfg.settleMs} cooldownMs=${cfg.cooldownMs} watchdogMs=${cfg.watchdogMs} dryRun=${cfg.dryRun}`)

  // 订阅状态看门狗：手机端掉线/恢复都记进日志，方便排查「为什么没振」
  if (typeof cfg.watchdogMs === 'number' && cfg.watchdogMs > 0) {
    try {
      watchdogTimer = setInterval(() => {
        void checkSubscribers()
      }, cfg.watchdogMs)
      watchdogTimer.unref?.()
      const warmup = setTimeout(() => {
        void checkSubscribers()
      }, 1500)
      warmup.unref?.()
    } catch {
      /* 看门狗失败不影响提醒 */
    }
  }

  // 自检：标记文件存在时，加载后发一条测试通知（只发一次，随后删除标记）
  const marker = expandHome(cfg.selftestMarker)
  try {
    if (marker !== undefined && existsSync(marker)) {
      unlinkSync(marker)
      const timer = setTimeout(() => {
        const proj = cfg.projects?.[0] ?? 'dsh'
        void send({ topic: cfg.topic, ...render('test', proj) }, `selftest/${proj}`)
      }, 1200)
      timer.unref?.()
      log('selftest marker found; will send one test notification')
    }
  } catch {
    /* 自检失败不影响插件 */
  }
}
