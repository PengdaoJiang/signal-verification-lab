"""Convert trusted XSim runner receipts to integrity-checked evaluation JSONL.

This does not run a model or simulator, authenticate an untrusted receipt, infer
physical signoff, or label hidden model reasoning. Missing evidence stays missing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from run_rtl import CASES, valid_result

CATALOG = Path(__file__).with_name("task_catalog.json")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_catalog() -> dict:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    ids = [task["id"] for task in data["tasks"]]
    if len(set(ids)) != len(ids) or set(ids) != set(CASES):
        raise ValueError("Task catalog and runner cases must match exactly")
    for task in data["tasks"]:
        bench = (ROOT / "tb" / (task["id"] + ".sv")).read_text(encoding="utf-8")
        if task["difficulty"] not in {"L1", "L2", "L3"}:
            raise ValueError("Unknown engineering-complexity tier")
        if not task["oracle_anchors"] or any(anchor not in bench for anchor in task["oracle_anchors"]):
            raise ValueError("Catalog check is not backed by the named testbench")
    return data


def expected_sources(case: str) -> set[str]:
    return set(CASES[case]) | {f"tb/{case}.sv", "scripts/run_all.tcl", "scripts/run_rtl.py"}


def read_receipt(path: Path) -> dict:
    def unique_keys(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError("Duplicate JSON key in receipt")
            obj[key] = value
        return obj

    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys)
    if not isinstance(value, dict) or type(value.get("schema_version")) is not int or value.get("schema_version") != 1:
        raise ValueError("Expected a version-1 run_rtl receipt")
    if value.get("evidence_class") != "behavioral_simulation":
        raise ValueError("Wrong evidence class")
    if not isinstance(value.get("source_sha256"), dict) or not isinstance(value.get("cases"), list):
        raise ValueError("Receipt is missing source or case records")
    names = [x.get("name") for x in value["cases"] if isinstance(x, dict)]
    if len(names) != len(value["cases"]) or len(names) != len(set(names)) or not set(names) <= set(CASES):
        raise ValueError("Duplicate, malformed or unknown case records")
    return value


def export_records(receipt_dir: Path, source_root: Path = ROOT, selected=None) -> list[dict]:
    catalog = load_catalog()
    tasks = {task["id"]: task for task in catalog["tasks"]}
    selected = list(tasks) if selected is None else list(selected)
    if not selected or len(set(selected)) != len(selected) or not set(selected) <= set(tasks):
        raise ValueError("Select unique known task IDs")
    receipt_path = receipt_dir / "receipt.json"
    receipt = read_receipt(receipt_path)
    cases = {item["name"]: item for item in receipt["cases"]}
    results = []
    for name in selected:
        task = tasks[name]
        row = {
            "schema_version": 1, "task_id": name, "category": task["category"],
            "difficulty": task["difficulty"], "evidence_class": "behavioral_simulation",
            "status": "unscorable", "reason_codes": [], "outcome_reward": None,
            "process_reward": None, "physical_metrics": None,
            "tool_exit_codes": None,
            "catalog_sha256": digest(CATALOG), "receipt_sha256": digest(receipt_path),
            "source_sha256": {}, "log_sha256": None,
        }
        source_errors = []
        for rel in sorted(expected_sources(name)):
            path = source_root / rel
            claimed = receipt["source_sha256"].get(rel)
            if not path.is_file() or not isinstance(claimed, str) or not re.fullmatch(r"[0-9a-f]{64}", claimed):
                source_errors.append("source_evidence_missing")
            elif digest(path) != claimed:
                source_errors.append("source_hash_mismatch")
            elif (rel.startswith("tb/") or rel.startswith("scripts/")) and digest(path) != digest(ROOT / rel):
                source_errors.append("trusted_evaluator_changed")
            else:
                row["source_sha256"][rel] = claimed
        if source_errors:
            row["reason_codes"] = sorted(set(source_errors))
        elif name not in cases:
            # The v1 runner only appends completed passing cases. It does not
            # attest which missing case failed, timed out, or was never selected.
            row["reason_codes"] = ["case_receipt_missing"]
        elif cases[name].get("passed") is not True:
            row["reason_codes"] = ["unsupported_case_verdict"]
        else:
            log = receipt_dir / name / "simulation.log"
            if not log.is_file():
                row["reason_codes"] = ["log_missing"]
            elif digest(log) != cases[name].get("log_sha256"):
                row["reason_codes"] = ["log_hash_mismatch"]
            else:
                row["log_sha256"] = digest(log)
                text = log.read_text(encoding="utf-8", errors="replace")
                fatal = re.search(r"(?:^|\n)\s*(?:fatal|error):", text, re.I)
                if not valid_result(text, name) or fatal:
                    row["reason_codes"] = ["receipt_log_verdict_conflict"]
                else:
                    row["status"], row["outcome_reward"] = "passed", 1.0
        results.append(row)
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt-dir", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--task", action="append", choices=list(CASES))
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    rows = export_records(args.receipt_dir.resolve(), args.source_root.resolve(), args.task)
    # Never replace a previously exported evaluation dataset.
    with args.out.open("x", encoding="utf-8", newline="\n") as stream:
        for row in rows:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
    scored = sum(row["status"] == "passed" for row in rows)
    print(json.dumps({"requested": len(rows), "scored": scored, "unscorable": len(rows) - scored}))
    return 0 if scored == len(rows) else 2


if __name__ == "__main__":
    raise SystemExit(main())
