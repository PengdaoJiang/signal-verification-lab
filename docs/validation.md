# Validation

Public-source regression performed on 2026-09-07:

| Testbench | Actual simulator | Result |
| --- | --- | --- |
| `tb_link_crc32c` | XSim 2025.2.1 | passed |
| `tb_link_clock_oe` | XSim 2025.2.1 | passed |
| `tb_link_endpoint` | XSim 2025.2.1 | passed |
| `tb_link_composed` | XSim 2025.2.1 | passed |
| `tb_finite_stream_engine` | XSim 2025.2.1 | passed |

The public source copy was run in a separate validation directory. Testbenches were elaborated sequentially with one worker. The runner checked process results and one exact completion marker per testbench; full output logs and source-hash receipts were retained privately because they include machine paths. Re-running `scripts/run_rtl.py` produces a new local receipt.

The hosted CI validates the Python/C numerical exercise, runner checks and a vendor-independent CRC testbench. It does not contain licensed vendor libraries and does not run the full XPM regression. Do not interpret its green status as physical board verification.

Historical finite-vector board observations motivated this design but are not replayed by these tests. This release makes no fresh board, RF, timing, throughput or BER claim. The common-link and segmented-engine benches also have different clock-stress coverage; simulation is not a substitute for physical CDC review.
