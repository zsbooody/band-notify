/**
 * dsh-band-notify 离线自测：伪造 DSH 的 ctx 与 session/event，本地起一个假 ntfy 收 POST。
 * 不碰真 ntfy、不碰 DSH 进程，只验证插件的判定逻辑。
 *
 *   node test/simulate.mjs
 */

import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { networkInterfaces, tmpdir } from 'node:os'
import { join } from 'node:path'

const { apply, name } = await import('../index.js')

const received = []
const server = createServer((req, res) => {
  // 订阅状态看门狗会查 /metrics：这里固定回 0（手机不在线），用来触发网段检查
  if (req.url === '/metrics') {
    res.writeHead(200, { 'Content-Type': 'text/plain' })
    res.end('# HELP ntfy_subscribers_total subscribers\nntfy_subscribers_total 0\n')
    return
  }
  let body = ''
  req.on('data', (chunk) => (body += chunk))
  req.on('end', () => {
    try {
      received.push({ url: req.url, headers: req.headers, payload: JSON.parse(body) })
    } catch {
      received.push({ url: req.url, raw: body })
    }
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end('{"id":"test"}')
  })
})

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const port = server.address().port
const base = `http://127.0.0.1:${port}`

const tmp = mkdtempSync(join(tmpdir(), 'dsh-band-notify-test-'))
const logFile = join(tmp, 'plugin.log')
const PROJECT_CWD = join(tmp, 'demo-project')
// 隔离用户真实配置，避免测试读到 ~/.config/band-notify/config.json。
process.env.BAND_NOTIFY_CONFIG_DIR = tmp

/** 假装是上一次网段生成的订阅页（192.0.2.0/24 是 TEST-NET，不会和本机 IP 撞） */
const subscribePage = join(tmp, 'subscribe.html')
writeFileSync(subscribePage, '<p><code>ntfy://192.0.2.123:2586/test-topic?secure=false</code></p>\n')

/** 收集插件注册的监听器 */
const listeners = new Map()
const disposers = []
const ctx = {
  on(type, fn) {
    if (!listeners.has(type)) listeners.set(type, [])
    listeners.get(type).push(fn)
  },
  effect(fn) {
    const dispose = fn()
    if (typeof dispose === 'function') disposers.push(dispose)
  },
}

apply(ctx, {
  server: base,
  topic: 'test-topic',
  settleMs: 80,
  cooldownMs: 500,
  quietMs: 0,
  timeoutMs: 1000,
  logFile,
  selftestMarker: join(tmp, 'no-selftest'),
  projects: [],
  watchdogMs: 120,
  subscribePage,
})

assert.equal(name, 'dsh-band-notify')
assert.ok(listeners.get('session/event')?.length === 1, '应注册一个 session/event 监听')

const emit = (session, type, data = {}) => {
  for (const fn of listeners.get('session/event') ?? []) fn(session, { type, data })
}

const session = (id, cwd = PROJECT_CWD, extra = {}) => ({
  id,
  header: { version: 4, id, createdAt: Date.now(), cwd, isSeeded: false, ...extra },
})

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
const posts = () => received.filter((item) => item.payload !== undefined)

let failures = 0
const check = (label, fn) => {
  try {
    fn()
    console.log(`  ok   ${label}`)
  } catch (error) {
    failures += 1
    console.log(`  FAIL ${label}: ${error.message}`)
  }
}

// 1) 正常回合结束 → settle 后发「停工等你」
emit(session('s1'), 'turn/start', { turn: 1 })
emit(session('s1'), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
await sleep(250)
check('completed 回合结束会提醒', () => {
  assert.equal(posts().length, 1, `期望 1 条，实际 ${posts().length}`)
  const payload = posts()[0].payload
  assert.equal(payload.topic, 'test-topic')
  assert.equal(payload.priority, 5)
  assert.match(payload.title, /停工等你/)
  assert.match(payload.message, /demo-project/)
  assert.deepEqual(payload.tags, ['robot'])
})

// 2) 回合结束但马上又开新回合 → 不发
received.length = 0
emit(session('s2'), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
emit(session('s2'), 'turn/start', { turn: 2 })
await sleep(250)
check('结束后立刻续跑不提醒', () => assert.equal(posts().length, 0, `期望 0 条，实际 ${posts().length}`))

// 3) 用户中断 → 不发
received.length = 0
emit(session('s3'), 'turn/end', { turn: 1, reason: { kind: 'aborted', reason: { kind: 'user' } } })
await sleep(250)
check('用户中断不提醒', () => assert.equal(posts().length, 0))

// 4) 子会话 / teammate 会话 → 不发
received.length = 0
emit(session('s4', PROJECT_CWD, { origin: 'subagent' }), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
emit(session('s4b', PROJECT_CWD, { origin: 'teammate' }), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
emit(session('s5', PROJECT_CWD, { delegationDepth: 1 }), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
await sleep(250)
check('子会话 / teammate 不提醒', () => assert.equal(posts().length, 0))

// 5) 权限审批 → 立即提醒
received.length = 0
emit(session('s6'), 'approval/asked', { id: 'a1', toolName: 'bash' })
await sleep(120)
check('权限审批立即提醒', () => {
  assert.equal(posts().length, 1)
  assert.match(posts()[0].payload.title, /需要你确认/)
  assert.match(posts()[0].payload.message, /bash/)
})

// 6) ask_user_question → 提醒
received.length = 0
emit(session('s7'), 'tool/call', { turn: 1, step: 1, callId: 'c1', name: 'ask_user_question', arguments: {} })
await sleep(120)
check('提问工具提醒', () => {
  assert.equal(posts().length, 1)
  assert.match(posts()[0].payload.title, /在等你回答/)
})

// 7) 同一会话冷却期内只发一次
received.length = 0
emit(session('s8'), 'approval/asked', { id: 'a2', toolName: 'bash' })
emit(session('s8'), 'approval/asked', { id: 'a3', toolName: 'write' })
await sleep(150)
check('冷却期内去重', () => assert.equal(posts().length, 1, `期望 1 条，实际 ${posts().length}`))

// 8) 出错停止 → 提醒
received.length = 0
emit(session('s9'), 'turn/end', { turn: 1, reason: { kind: 'error', error: { message: 'boom' } } })
await sleep(250)
check('出错停止提醒', () => {
  assert.equal(posts().length, 1)
  assert.match(posts()[0].payload.title, /因错误停止/)
  assert.deepEqual(posts()[0].payload.tags, ['rotating_light'])
})

// 9) 脏数据不崩
received.length = 0
check('脏数据不抛异常', () => {
  emit(null, 'turn/end', {})
  emit(session('s10'), null, {})
  emit({ id: 's11' }, 'turn/end', { reason: { kind: 'completed' } })
  emit(session('s12'), 'turn/end', {})
})

// 10) 网段变化：subscribe.html 里是旧 IP → 日志里要能看出来
const hasLanIp = Object.values(networkInterfaces()).flat().some(
  (net) => net?.family === 'IPv4' && !net.internal,
)
await sleep(300)
if (hasLanIp) {
  check('发现订阅地址是旧 IP', () => {
    const text = readFileSync(logFile, 'utf8')
    assert.match(text, /network changed:/)
  })
} else {
  console.log('  skip 发现订阅地址是旧 IP（本机没有非回环 IPv4）')
}

// 11) 重放上一回合的 turn/end → 不提醒
received.length = 0
emit(session('s13'), 'turn/start', { turn: 2 })
emit(session('s13'), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
await sleep(250)
check('旧 turn/end 不提醒', () => assert.equal(posts().length, 0, `期望 0 条，实际 ${posts().length}`))

// 12) 同一回合的 turn/end 重复投递 → 只提醒一次
received.length = 0
emit(session('s14'), 'turn/start', { turn: 1 })
emit(session('s14'), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
emit(session('s14'), 'turn/end', { turn: 1, reason: { kind: 'completed' } })
await sleep(250)
check('同一回合重复 turn/end 只提醒一次', () => assert.equal(posts().length, 1, `期望 1 条，实际 ${posts().length}`))

// 13) dispose 清掉定时器
for (const dispose of disposers) dispose()

await sleep(50)
server.close()
console.log(`\n日志：${logFile}`)
if (failures > 0) {
  console.log(`\n${failures} 项失败`)
  process.exit(1)
}
console.log('\n全部通过')
