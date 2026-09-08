"""Run source-only XSim regressions. Never opens hardware or builds a bitstream."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
COMMON = [
    "rtl/common/link_crc32c.sv", "rtl/common/link_reset_sync.sv",
    "rtl/common/link_async_fifo.sv", "rtl/common/link_clock_oe.sv",
    "rtl/common/link_tx_framer.sv", "rtl/common/link_rx_parser.sv",
    "rtl/common/minimal_link_core.sv",
]
FINITE = ["rtl/finite/finite_stream_engine.sv", "rtl/finite/finite_stream_bridge.sv"]
CASES = {
    "tb_link_crc32c": ["rtl/common/link_crc32c.sv"],
    "tb_link_clock_oe": ["rtl/common/link_clock_oe.sv"],
    "tb_link_endpoint": COMMON,
    "tb_link_composed": COMMON,
    "tb_finite_stream_engine": FINITE,
}


def valid_result(log: str, name: str) -> bool:
    marker = name.upper() + "=PASS"
    return (len(re.findall(r"^" + re.escape(marker) + r"\r?$", log, re.M)) == 1
            and not re.search(r"(?:^|\n)\s*(?:Fatal:|ERROR:)|TB_\w*FAIL=", log))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(vivado_bin: Path, output: Path, cases: list[str]) -> dict:
    if output.exists():
        raise ValueError("Choose a new output directory; existing evidence is never replaced")
    suffix = ".bat" if os.name == "nt" else ""
    commands = {name: vivado_bin / (name + suffix) for name in ("xvlog", "xelab", "xsim")}
    glbl = vivado_bin.parent / "data/verilog/src/glbl.v"
    for path in [*commands.values(), glbl]:
        if not path.is_file():
            raise FileNotFoundError(path)
    output = output.resolve()
    output.mkdir(parents=True)
    sources = sorted({relative for case in cases for relative in CASES[case]}
                     | {f"tb/{case}.sv" for case in cases} | {"scripts/run_all.tcl", "scripts/run_rtl.py"})
    receipt = {"schema_version": 1, "evidence_class": "behavioral_simulation",
               "workers": 1, "hardware_access": False, "bitstream_build": False,
               "source_sha256": {relative: sha256(ROOT / relative) for relative in sources},
               "cases": []}

    def invoke(argv: list[str], cwd: Path, name: str) -> str:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=240,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        log = result.stdout + "\n" + result.stderr
        (cwd / (name + ".log")).write_text(log, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"{name} failed with exit {result.returncode}; inspect its local log")
        return log

    try:
        receipt["simulator_version"] = invoke([str(commands["xvlog"]), "--version"], output, "version").strip()
        for case in cases:
            current = output / case
            current.mkdir()
            files = [str(ROOT / relative) for relative in CASES[case]] + [str(ROOT / f"tb/{case}.sv")]
            invoke([str(commands["xvlog"]), "--sv", "--work", "work", *files], current, "compile")
            invoke([str(commands["xvlog"]), "--work", "work", str(glbl)], current, "glbl")
            invoke([str(commands["xelab"]), "--mt", "off", "--debug", "typical",
                    "-L", "xpm", "-L", "unisims_ver", "--snapshot", case + "_snapshot",
                    case, "glbl"], current, "elaborate")
            invoke([str(commands["xsim"]), case + "_snapshot", "--tclbatch",
                    (ROOT / "scripts/run_all.tcl").as_posix(), "--onerror", "quit",
                    "--log", (current / "simulation.log").as_posix()], current, "run")
            log = (current / "simulation.log").read_text(encoding="utf-8", errors="replace")
            if not valid_result(log, case):
                raise RuntimeError(f"{case}: failed or missing/duplicate completion marker")
            receipt["cases"].append({"name": case, "passed": True,
                                     "log_sha256": sha256(current / "simulation.log")})
            print(case + ": passed", flush=True)
        receipt["passed"] = True
    except Exception as exc:
        receipt["passed"] = False
        receipt["error_type"] = type(exc).__name__
        raise
    finally:
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return receipt


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado-bin", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--case", choices=list(CASES), action="append")
    args = parser.parse_args()
    try:
        run(args.vivado_bin.resolve(), args.out, args.case or list(CASES))
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
