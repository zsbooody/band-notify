#!/usr/bin/env python3
"""band-notify 共享配置（Python 版）。

优先级：环境变量 > ${XDG_CONFIG_HOME:-~/.config}/band-notify/config.json > 默认值。
zcode 闸门/等待器与其它 Python 工具都从这里读配置。
"""
from __future__ import annotations

import json
import os
import pathlib
from typing import Any


_STATE_HOME = pathlib.Path(
    os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state")
)
DEFAULT_STATE_DIR = str(_STATE_HOME / "band-notify")

DEFAULTS: dict[str, Any] = {
    "server": "http://127.0.0.1:2586",
    "port": 2586,
    "topic": "",
    "lanInterface": "wlan0",
    "stateDir": DEFAULT_STATE_DIR,
    "zcodeLogDir": "~/.zcode/cli/log",
    "zcodeProcess": "/opt/ZCode/zcode",
    "minRunMs": 10000,
    "confirmMs": 180000,
    "retryMs": 15000,
    "firstDelay": 5,
    "quietSeconds": 15,
    "maxWait": 5400,
    "cooldownSeconds": 60,
    "subscribePage": str(pathlib.Path(DEFAULT_STATE_DIR) / "subscribe.html"),
}

ENV_MAP = {
    "BAND_NOTIFY_SERVER": "server",
    "BAND_NOTIFY_PORT": "port",
    "BAND_NOTIFY_TOPIC": "topic",
    "BAND_NOTIFY_IFACE": "lanInterface",
    "BAND_NOTIFY_STATE_DIR": "stateDir",
    "BAND_NOTIFY_ZCODE_LOG_DIR": "zcodeLogDir",
    "BAND_NOTIFY_ZCODE_PROCESS": "zcodeProcess",
    "BAND_NOTIFY_MIN_RUN_MS": "minRunMs",
    "BAND_NOTIFY_CONFIRM_MS": "confirmMs",
    "BAND_NOTIFY_RETRY_MS": "retryMs",
    "BAND_NOTIFY_FIRST_DELAY": "firstDelay",
    "BAND_NOTIFY_QUIET_SECONDS": "quietSeconds",
    "BAND_NOTIFY_MAX_WAIT": "maxWait",
    "BAND_NOTIFY_COOLDOWN": "cooldownSeconds",
    "BAND_NOTIFY_SUBSCRIBE_PAGE": "subscribePage",
}


def _expand_home(value: Any) -> Any:
    if isinstance(value, str) and value.startswith("~/"):
        return str(pathlib.Path.home()) + value[1:]
    return value


def config_path() -> pathlib.Path:
    config_dir = pathlib.Path(
        os.environ.get(
            "BAND_NOTIFY_CONFIG_DIR",
            pathlib.Path(os.environ.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config"))
            / "band-notify",
        )
    )
    return config_dir / "config.json"


def load() -> dict[str, Any]:
    cfg: dict[str, Any] = dict(DEFAULTS)
    try:
        cfg.update(json.loads(config_path().read_text(encoding="utf-8")))
    except (OSError, ValueError):
        pass

    for env_name, key in ENV_MAP.items():
        value = os.environ.get(env_name)
        if value not in (None, ""):
            cfg[key] = value

    for key in ("stateDir", "zcodeLogDir", "subscribePage"):
        cfg[key] = _expand_home(cfg.get(key, ""))

    try:
        cfg["port"] = int(cfg.get("port") or 2586)
    except (TypeError, ValueError):
        cfg["port"] = 2586

    for key in ("minRunMs", "confirmMs", "retryMs"):
        try:
            cfg[key] = int(cfg.get(key) or DEFAULTS[key])
        except (TypeError, ValueError):
            cfg[key] = DEFAULTS[key]

    return cfg


def state_dir() -> pathlib.Path:
    path = pathlib.Path(load()["stateDir"])
    path.mkdir(parents=True, exist_ok=True)
    return path
