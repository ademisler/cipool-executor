#!/usr/bin/env python3
"""Run one immutable CI Pool workload with foreground liveness and hard timeout."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from typing import TextIO


def _kill_group(pid: int, signum: int) -> None:
    try:
        os.killpg(pid, signum)
    except ProcessLookupError:
        pass


def supervise(
    command: str,
    job_key: str,
    timeout_seconds: float,
    *,
    heartbeat_seconds: float = 30.0,
    stdout: TextIO = sys.stdout,
    stderr: TextIO = sys.stderr,
) -> int:
    if timeout_seconds <= 0 or timeout_seconds > 3300:
        raise ValueError("timeout must be within the CI Pool free-plan workload bound")
    if heartbeat_seconds <= 0:
        raise ValueError("heartbeat interval must be positive")

    started = time.monotonic()
    deadline = started + timeout_seconds
    next_heartbeat = started + heartbeat_seconds
    forwarded_signal: int | None = None
    proc = subprocess.Popen(["/bin/bash", "-lc", command], start_new_session=True)

    previous: dict[int, object] = {}

    def forward(signum: int, _frame: object) -> None:
        nonlocal forwarded_signal
        forwarded_signal = signum
        _kill_group(proc.pid, signum)

    can_install_handlers = True
    try:
        import threading
        can_install_handlers = threading.current_thread() is threading.main_thread()
    except Exception:
        can_install_handlers = False
    if can_install_handlers:
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous[signum] = signal.getsignal(signum)
            signal.signal(signum, forward)

    timed_out = False
    try:
        while proc.poll() is None:
            now = time.monotonic()
            if forwarded_signal is not None:
                break
            if now >= deadline:
                timed_out = True
                _kill_group(proc.pid, signal.SIGTERM)
                break
            if now >= next_heartbeat:
                elapsed = int(now - started)
                print(f"CIPOOL_EXECUTOR_HEARTBEAT job={job_key} elapsed={elapsed}s", file=stdout, flush=True)
                next_heartbeat = now + heartbeat_seconds
            wake_in = min(1.0, max(0.02, deadline - now), max(0.02, next_heartbeat - now))
            time.sleep(wake_in)

        if timed_out or forwarded_signal is not None:
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                _kill_group(proc.pid, signal.SIGKILL)
                proc.wait()
            if timed_out:
                print(
                    f"CIPOOL_EXECUTOR_TIMEOUT job={job_key} limit={int(timeout_seconds)}s",
                    file=stderr,
                    flush=True,
                )
                return 124
            return 128 + int(forwarded_signal)
        return int(proc.returncode or 0)
    finally:
        if can_install_handlers:
            for signum, handler in previous.items():
                signal.signal(signum, handler)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: run-workload.py TIMEOUT_SECONDS JOB_KEY COMMAND", file=sys.stderr)
        return 64
    try:
        timeout_seconds = int(argv[1])
    except ValueError:
        print("invalid timeout", file=sys.stderr)
        return 64
    try:
        return supervise(argv[3], argv[2], timeout_seconds)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
