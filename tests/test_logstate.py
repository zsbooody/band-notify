#!/usr/bin/env python3
"""logstate.is_resume_event 的回归测试。

2026-10-08 的教训：把 background_task.tracking.terminal.* / subagent.completed /
dynamic_workflow.completed 当成“会话又开始干活”，会让 Stop 之后的真提醒被
skip(session resumed) 跳过。这里锁住“只认起头事件”的行为。
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib/zcode-notify"))

import logstate  # noqa: E402


class ResumeEventTest(unittest.TestCase):
    def test_start_events_are_resume(self):
        for event in (
            "turn.started",
            "model.request.started",
            "tool.call.started",
            "background_task.tracking.started",
            "subagent.started",
            "dynamic_workflow.started",
            "session.resumed",
        ):
            with self.subTest(event=event):
                self.assertTrue(logstate.is_resume_event(event))

    def test_terminal_events_are_not_resume(self):
        for event in (
            "turn.completed",
            "turn.failed",
            "model.request.completed",
            "tool.call.completed",
            "tool.call.failed",
            "background_task.tracking.terminal.completed",
            "background_task.tracking.terminal.failed",
            "subagent.completed",
            "dynamic_workflow.completed",
            # 噪音事件即使以 .started 结尾也不该被当成续跑
            "session.event.persistence.started",
        ):
            with self.subTest(event=event):
                self.assertFalse(logstate.is_resume_event(event))


if __name__ == "__main__":
    unittest.main()
