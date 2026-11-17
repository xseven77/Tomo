#!/usr/bin/env python3
"""Probe the installed app-server's ephemeral ownership boundary, without a model turn."""

import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid


def request(process, method, params=None):
    identity = str(uuid.uuid4())
    process.stdin.write((json.dumps({"id": identity, "method": method, "params": params or {}}) + "\n").encode())
    process.stdin.flush()
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if not select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        line = process.stdout.readline()
        if not line:
            raise RuntimeError("app-server exited")
        frame = json.loads(line)
        if frame.get("id") == identity:
            return frame
    raise TimeoutError(method)


def initialized(process):
    reply = request(process, "initialize", {"clientInfo": {"name": "TomoEphemeralProbe", "version": "1.0"},
                                            "capabilities": {"experimentalApi": False}})
    if not reply.get("result", {}).get("userAgent"):
        raise RuntimeError("invalid handshake")
    process.stdin.write(b'{"method":"initialized"}\n')
    process.stdin.flush()


def main():
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("codex CLI not installed")
    with tempfile.TemporaryDirectory(prefix="tomo-ephemeral-probe-") as base:
        root = Path(base)
        account, workspace = root / "account", root / "workspace"
        account.mkdir(mode=0o700)
        workspace.mkdir(mode=0o700)
        environment = dict(os.environ, CODEX_HOME=str(account), HOME=str(root), XDG_CONFIG_HOME=str(root / "config"))

        def launch():
            return subprocess.Popen([executable, "app-server", "--stdio"], cwd=workspace, env=environment,
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)

        first = launch()
        second = None
        try:
            initialized(first)
            started = request(first, "thread/start", {"ephemeral": True, "cwd": str(workspace)})
            thread = started.get("result", {}).get("thread", {})
            thread_id = thread.get("id")
            if not thread_id or thread.get("ephemeral") is not True or thread.get("path") is not None:
                raise RuntimeError("thread/start did not confirm an ephemeral, pathless thread")
            if thread.get("cwd") != str(workspace):
                raise RuntimeError("thread/start did not confirm the selected workspace")
            same_process = request(first, "thread/read", {"threadId": thread_id, "includeTurns": False})
            if same_process.get("result", {}).get("thread", {}).get("id") != thread_id:
                raise RuntimeError("owner process cannot read its thread")
            metadata = same_process["result"]["thread"]
            if metadata.get("ephemeral") is not True or metadata.get("path") is not None:
                raise RuntimeError("ephemeral metadata lost private ownership markers")
            if metadata.get("status", {}).get("type") not in ("idle", "notLoaded"):
                raise RuntimeError("new ephemeral thread is not idle")
            if not isinstance(metadata.get("createdAt"), int) or not isinstance(metadata.get("updatedAt"), int):
                raise RuntimeError("ephemeral metadata lacks baseline timestamps: " + repr(sorted(metadata.keys())))
            if metadata.get("turns") not in (None, []):
                raise RuntimeError("ephemeral metadata unexpectedly includes turns")
            full_read = request(first, "thread/read", {"threadId": thread_id, "includeTurns": True})
            if full_read.get("error", {}).get("code") != -32600:
                raise RuntimeError("installed CLI changed ephemeral full-read behavior; reassess bootstrap")
            second = launch()
            initialized(second)
            other_process = request(second, "thread/read", {"threadId": thread_id, "includeTurns": False})
            if "result" in other_process:
                raise RuntimeError("another process can read the ephemeral thread")
            other_resume = request(second, "thread/resume", {"threadId": thread_id, "excludeTurns": True})
            if "result" in other_resume:
                raise RuntimeError("another process can resume the ephemeral thread")
            indexed = list(account.rglob("*.jsonl"))
            database = account / "state_5.sqlite"
            if database.exists():
                with sqlite3.connect(f"file:{database}?mode=ro", uri=True) as connection:
                    indexed += connection.execute("SELECT id FROM threads WHERE id = ?", (thread_id,)).fetchall()
            if indexed:
                raise RuntimeError("ephemeral thread appeared in a rollout or session index")
            print("installed CLI: ephemeral thread stays readable only in its owner; another process cannot read/resume; no rollout/index written")
        finally:
            for process in (first, second):
                if process:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("ephemeral probe failed:", type(error).__name__, str(error)[:160], file=sys.stderr)
        sys.exit(1)
