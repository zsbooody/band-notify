#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ZCode 运行时日志 → 「在飞工作单元」判定（zcode-notify-gate / zcode-settle-wait 共用）

为什么不能只看“最近有没有新日志行”：
    GLM 单次模型请求实测要 15~304 秒（2026-10-08 日志），这段时间**一行日志都不写**。
    把“安静 15 秒”当成“活干完了”，就会在 turn 跑到一半时误报「zcode 停工等你」。
所以必须显式跟踪“还没收尾的工作单元”：

    · turn       turn.started 之后没有 turn.completed / turn.failed
                 （模型请求、工具调用都在 turn 内发生，turn 没结束就是还在干活）
    · 后台任务   background_task.tracking.started 之后没有 .terminal*
                 （dwfrun-* = 工作流，exec_* = 后台 Bash；它可能比派发它的 turn 活得久）
    · 工具调用   tool.call.started 之后没有 tool.call.completed / .failed
                 （兜底：前台长命令会让 turn 长时间没日志，这条防止 turn 被判“太久没动”）

另外：日志要**整份**扫，不能只 tail 尾部 N 字节——跑一小时的工作流，
它的 started 事件会被 tail 窗口挤出去，导致在飞判定凭空消失（2026-10-08 16:24 事故）。

典型用法：

    st = LogState("/home/me/.zcode/cli/log")
    while True:
        units, last_work = st.poll()      # poll 是增量的：每个字节只解析一次
        if not units and time.time() - last_work >= QUIET:
            ...

自测可用环境变量：ZCODE_NOTIFY_INFLIGHT_MAX_AGE / ZCODE_NOTIFY_TURN_STALE /
ZCODE_NOTIFY_TOOL_STALE（把旧的日志快照当成“当时”来复现，需要把后两个设大）。
"""
import json
import os
import pathlib
import time
from datetime import datetime


def _env_float(name, default):
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default


# 下面三个阈值是“陈旧保护”：单元开着但很久没动静，就当它死了（进程崩了/日志残缺），
# 否则提醒会被一个永远不收尾的单元卡死。三个都可用环境变量覆盖（自测用）。
INFLIGHT_MAX_AGE = _env_float("ZCODE_NOTIFY_INFLIGHT_MAX_AGE", 6 * 3600)  # 在飞单元最长算活 6 小时
TURN_STALE = _env_float("ZCODE_NOTIFY_TURN_STALE", 900)   # turn 开着、会话 15 分钟没日志 → 当它死了（实测 turn 内最长静默 304 秒）
TOOL_STALE = _env_float("ZCODE_NOTIFY_TOOL_STALE", 1800)  # 工具调用开着、30 分钟没动静 → 当它死了（实测最长 147 秒）
MAX_DAYS = 2                                              # 只看最近两天的日志文件（跨零点够用）

# 只有这些前缀的事件算“在工作”（排除 memory_sample / session.event.persistence.* 之类的噪音）
WORK_PREFIXES = (
    "turn.started", "turn.completed", "turn.failed",
    "model.request.", "tool.call.",
    "background_task.", "subagent.", "session.resumed",
    "compact.", "dynamic_workflow.", "task.",
)

# “这个会话又活过来了”事件：只看“起头”的那种。收尾类事件
# （turn.phase.completed / model.request.completed / background_task.tracking.terminal.* /
# subagent.completed / dynamic_workflow.completed）不算；拿它们当“续跑”会漏掉真提醒。
# 用 `.start` 前缀可以同时覆盖 `.start` 与 `.started`。
RESUME_PREFIXES = (
    "turn.started",
    "model.request.started",
    "tool.call.started",
    "background_task.tracking.start",
    "subagent.start",
    "dynamic_workflow.start",
    "session.resumed",
)


def is_resume_event(event):
    """是不是“会话又开始干活”的事件（用来判断 Stop 之后它是不是续跑了）。

    只认起头事件；`.terminal*`、`.completed`、`.failed` 等收尾事件一律不算。
    """
    return bool(event) and event.startswith(RESUME_PREFIXES)


def log_files(log_dir, days=MAX_DAYS):
    """最近 days 天的 ZCode 日志（按文件名即日期排序）。"""
    files = sorted(pathlib.Path(log_dir).glob("zcode-*.jsonl"))
    return files[-days:] if days > 0 else files


def _epoch(record):
    try:
        return datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00")).timestamp()
    except (KeyError, ValueError, AttributeError, TypeError):
        return None


class LogState:
    """增量解析日志，维护在飞单元与“最后一次工作事件”。"""

    def __init__(self, log_dir):
        self.log_dir = pathlib.Path(log_dir)
        self._offsets = {}
        self._buffers = {}
        self.turns = {}       # (sessionId, turnId) -> 开始时间
        self.bg = {}          # taskId -> 开始时间
        self.tools = {}       # toolCallId -> (开始时间, 工具名)
        self.last_seen = {}   # sessionId -> 该会话最后一条日志的时间（任何事件，含噪音）
        self.last_work = 0.0  # 最后一次“工作类”事件的时间

    # -- 内部 ---------------------------------------------------------------
    def _reset(self):
        self._offsets.clear()
        self._buffers.clear()
        self.turns.clear()
        self.bg.clear()
        self.tools.clear()
        self.last_seen.clear()
        self.last_work = 0.0

    def _feed(self, line):
        if not line.strip():
            return
        try:
            record = json.loads(line)
        except ValueError:
            return
        ts = _epoch(record)
        if ts is None:
            return
        sid = record.get("sessionId")
        if sid and ts > self.last_seen.get(sid, 0):
            self.last_seen[sid] = ts
        event = record.get("event") or ""
        ctx = record.get("context") or {}
        if event == "turn.started":
            self.turns[(sid, record.get("turnId"))] = ts
        elif event in ("turn.completed", "turn.failed"):
            self.turns.pop((sid, record.get("turnId")), None)
        elif event == "background_task.tracking.started":
            tid = ctx.get("taskId")
            if tid:
                self.bg[tid] = ts
        elif event.startswith("background_task.tracking.terminal"):
            self.bg.pop(ctx.get("taskId"), None)
        elif event == "tool.call.started":
            cid = record.get("toolCallId")
            if cid:
                self.tools[cid] = (ts, ctx.get("toolName") or "")
        elif event.startswith(("tool.call.completed", "tool.call.failed", "tool.call.cancelled")):
            self.tools.pop(record.get("toolCallId"), None)
        if event.startswith(WORK_PREFIXES) and ts > self.last_work:
            self.last_work = ts
    # -- 对外 ---------------------------------------------------------------
    def poll(self):
        """读到日志末尾，返回 (在飞单元 dict, 最后一次工作事件时间)。

        在飞单元 key 形如 `turn:<会话>:<turnId>` / `bg:<taskId>` / `tool:<toolCallId>`，
        值为开始时间（epoch 秒）。
        """
        for path in log_files(self.log_dir):
            key = str(path)
            try:
                size = path.stat().st_size
            except OSError:
                continue
            if size < self._offsets.get(key, 0):
                self._reset()  # 日志被清理/轮转，从头重来
            offset = self._offsets.get(key, 0)
            if size <= offset:
                continue
            try:
                with open(path, "rb") as f:
                    f.seek(offset)
                    data = f.read()
            except OSError:
                continue
            self._offsets[key] = offset + len(data)
            buf = self._buffers.get(key, b"") + data
            lines = buf.split(b"\n")
            self._buffers[key] = lines.pop()  # 最后一段可能是半行，留到下次
            for raw in lines:
                self._feed(raw.decode("utf-8", "replace"))
        return self.units(), self.last_work

    def units(self, exclude_turn_sessions=()):
        """还没收尾的工作单元。exclude_turn_sessions 里的会话忽略其 turn
        （Stop 钩子说“这个会话停了”，就不必再用它自己的 turn 去否决这次提醒）。"""
        now = time.time()
        out = {}
        for (sid, tid), started in self.turns.items():
            if sid in exclude_turn_sessions:
                continue
            if now - started >= INFLIGHT_MAX_AGE:
                continue
            if now - self.last_seen.get(sid, started) >= TURN_STALE:
                continue
            out["turn:%s:%s" % (sid, tid)] = started
        for tid, started in self.bg.items():
            if now - started < INFLIGHT_MAX_AGE:
                out["bg:%s" % tid] = started
        for cid, (started, name) in self.tools.items():
            if now - started >= TOOL_STALE:
                continue
            out["tool:%s(%s)" % (cid, name)] = started
        return out
