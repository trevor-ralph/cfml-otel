"""TestBox unit specs (tests/specs), run inside each engine: the CFML logic in isolation."""
from __future__ import annotations

import json

import harness


def _failures(node: dict, path: str = "") -> list[str]:
    out = []
    for spec in node.get("specStats", []):
        if spec.get("status") in ("Failed", "Error"):
            out.append(f"{path}{spec.get('name')}: {spec.get('failMessage') or spec.get('error', {}).get('message', '')}")
    for child in node.get("suiteStats", []) + node.get("bundleStats", []):
        out += _failures(child, f"{path}{child.get('name', '')} > ")
    return out


def test_testbox_specs_pass(run):
    status, body = harness.http(f"{run.target.base}/cfml-otel/tests/specs/runner.cfm", timeout=180)
    assert status == 200, body[:2000]
    report = json.loads(body)
    assert report["totalSpecs"] > 0, report
    failures = _failures(report)
    assert report["totalFail"] == 0 and report["totalError"] == 0, "\n".join(failures)
    print(f"{run.target.name}: {report['totalPass']} passed, {report['totalSkipped']} skipped")
