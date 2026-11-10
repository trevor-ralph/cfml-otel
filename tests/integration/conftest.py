"""Phase 1 (once per session): wait for the stack, drive every selected engine, wait for export.
Phase 2: the tests, parametrized by engine (ENGINES=lucee7,acf2023,...)."""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

import harness

RESULTS = Path(os.environ.get("RESULTS_DIR", "/results" if not harness.LOCAL else "../results"))


def pytest_generate_tests(metafunc):
    if "engine" in metafunc.fixturenames:
        names = [t.name for t in harness.engines()]
        metafunc.parametrize("engine", names, ids=names, scope="session")


@pytest.fixture(scope="session")
def runs() -> dict[str, harness.Run]:
    targets = harness.engines()
    harness.wait_until_ready(targets)
    out = {}
    for t in targets:
        print(f"driving {t.name}", flush=True)
        out[t.name] = harness.drive(t)
    print(f"waiting {harness.EXPORT_WAIT}s for export...", flush=True)
    time.sleep(harness.EXPORT_WAIT)
    try:
        RESULTS.mkdir(parents=True, exist_ok=True)
        (RESULTS / "scenario-responses.json").write_text(
            json.dumps({k: v.response for k, v in out.items()}, indent=2), encoding="utf-8")
    except OSError:
        pass
    return out


@pytest.fixture
def run(runs, engine) -> harness.Run:
    return runs[engine]


@pytest.fixture
def server_id(run) -> str:
    return run.response.get("serverSpanId", "")


@pytest.fixture
def named(run) -> dict[str, harness.Span]:
    return harness.by_name(run.trace_id)
