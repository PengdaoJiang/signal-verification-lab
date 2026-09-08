from __future__ import annotations

import argparse
import hashlib
import json
import platform
import random
import sys
from datetime import datetime, timezone
from pathlib import Path

from reference import CFilter, compare, reference


def run(library, seed=20260907):
    rng = random.Random(seed)
    signals = [[32767] + [0] * 31, [-32768] + [0] * 31,
               [32767] * 64, [-32768] * 64, [32767, -32768] * 32,
               [-1, 0, 1, 0, -3, 2], [], [1], [-1]]
    signals += [[rng.randint(-32768, 32767) for _ in range(n)]
                for n in [2, 3, 7, 31, 257, 1024, 4096]]
    coefficients = [[8192, 16384, 8192], [32767, 32767, 32767],
                    [-32768, 32767, -32768], [1, -1, 1], [0, 0, 0]]
    cases = []
    for ci, coeff in enumerate(coefficients):
        for si, samples in enumerate(signals):
            kernel = CFilter(library, coeff)
            expected = reference(samples, coeff)
            whole = compare(expected, kernel.process(samples))
            kernel.reset()
            output, position = [], 0
            while position < len(samples):
                count = rng.randint(1, 23)
                output.extend(kernel.process(samples[position:position + count]))
                position += count
            chunked = compare(expected, output)
            kernel.reset()
            reset = compare(expected, kernel.process(samples))
            cases.append({"id": f"coeff-{ci}-signal-{si}", "samples": len(samples),
                          "whole": whole, "chunked": chunked, "reset": reset})
    baseline = reference([2000, -5000, 9000, 0, 3000], coefficients[0])
    bit_fault = list(baseline)
    bit_fault[2] ^= 1
    faults = {"one_bit": compare(baseline, bit_fault),
              "dropped_sample": compare(baseline, baseline[:-1]),
              "duplicated_sample": compare(baseline, baseline + baseline[-1:])}
    success = all(c[key]["match"] for c in cases for key in ["whole", "chunked", "reset"])
    success = success and all(not result["match"] for result in faults.values())
    root = Path(__file__).resolve().parent
    paths = [root / "src/fir_q15.c", root / "reference.py", root / "verify.py"]
    return {"schema_version": 1, "created_utc": datetime.now(timezone.utc).isoformat(),
            "evidence_level": "local_compiled_C_vs_integer_reference", "synthetic_signals": True,
            "python": sys.version.split()[0], "platform": platform.system(), "machine": platform.machine(),
            "seed": seed, "case_count": len(cases), "samples_per_comparison_mode": sum(c["samples"] for c in cases),
            "source_sha256": {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
            "library_sha256": hashlib.sha256(Path(library).read_bytes()).hexdigest(),
            "all_passed": success, "fault_detection": faults, "cases": cases}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20260907)
    args = parser.parse_args()
    result = run(args.library, args.seed)
    args.out.mkdir(parents=True, exist_ok=False)
    (args.out / "receipt.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: result[k] for k in ["evidence_level", "case_count", "samples_per_comparison_mode", "all_passed"]}, indent=2))
    return 0 if result["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
