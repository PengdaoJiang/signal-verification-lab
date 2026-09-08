# Signal Verification Lab

A source-derived **FPGA data-path and DSP verification** project: frame-level acceptance, clock-domain boundaries, finite full-duplex capture, and independent numerical checks.

The RTL and self-checking testbenches come from an existing engineering project. The repository focuses on the hardware-independent datapaths: how accepted data moves across clock domains, packet boundaries and backpressure without admitting corrupt frames or replaying words. Board wiring, constraints, vendor IP and programming scripts are outside the source release.

Start with [the failure cases and code-reading route](docs/engineering-cases.md), then the [architecture](docs/rtl-architecture.md). The Python/C FIR is a separate fixed-point numerical exercise.

## What is included

| Subsystem | Implementation | Main engineering problem |
| --- | --- | --- |
| Framed digital link | `rtl/common/` | CRC-32C, sequencing, commit-after-validation, FIFO capacity, reset/arm and two clock domains |
| Finite streaming engine | `rtl/finite/` | 512-bit / four-segment LBUS-style source and capture, packet-boundary takeover, halt/resume and receive alignment |
| Management bridge | `rtl/finite/finite_stream_bridge.sv` | Atomic request/response transfer between management and user clock domains |
| Self-checking simulation | `tb/`, `scripts/run_rtl.py` | Independent expected vectors, fault injection, exact capture comparison and strict completion markers |
| Fixed-point reference | `reference.py`, `src/fir_q15.c`, `verify.py` | Python/C agreement, negative rounding, saturation, streaming state and injected sample faults |

The finite engine exposes a bounded 64 × 512-bit transaction, not an unrestricted production streaming interface. Its testbench compares captures outside the DUT; expected payloads are not embedded as DUT acceptance oracles.

## RTL simulation

Install a compatible AMD Vivado/XSim locally. The RTL references XPM and device primitives supplied by that installation; their source is **not bundled or relicensed**. The source-only simulation workflow was verified with XSim 2025.2.1.

```text
python scripts/run_rtl.py --vivado-bin PATH_TO_VIVADO/bin --out rtl-output
```

Use a new output directory. Five testbenches run sequentially with one elaboration worker:

- CRC-32C known-answer test.
- Forwarded-clock output-enable start/stop and safety release.
- Endpoint receive acceptance, CRC/sequence rejection and reset abort.
- Two-endpoint composed full-duplex exact comparison with distinct clocks.
- Finite segmented streaming, packet-boundary takeover, ready halt/resume, all four start offsets, terminal error rejection and management bridge.

No hardware server is opened, no bitstream is generated, and no board is programmed. `receipt.json` binds results to the public source hashes. Passing behavioral simulation does not establish timing closure, physical CDC quality, RF performance, throughput or BER.

## Portable Python/C example

Python 3.10+; full cross-language verification also needs a C compiler. On Linux:

```sh
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror -O2 -fPIC -shared src/fir_q15.c -o build/libfir_q15.so
export SIGNAL_FIR_LIBRARY="$PWD/build/libfir_q15.so"
python -m unittest discover -s tests -v
python verify.py --library build/libfir_q15.so --out verification-output
```

Windows, in an x64 Visual Studio Developer Command Prompt:

```bat
mkdir build
cl /nologo /W4 /WX /O2 /LD src\fir_q15.c /Fo:build\fir_q15.obj /link /OUT:build\fir_q15.dll /IMPLIB:build\fir_q15.lib
set SIGNAL_FIR_LIBRARY=%CD%\build\fir_q15.dll
python -m unittest discover -s tests -v
python verify.py --library build\fir_q15.dll --out verification-output
```

Without `SIGNAL_FIR_LIBRARY`, cross-language unit tests are explicitly skipped. The verification CLI always requires the compiled C library. The numeric contract is signed Q1.15, int64 accumulation, floor toward negative infinity, saturation and zero initial state.

## Scope and provenance

The common-link RTL, finite engine/bridge and their testbenches are source-derived. Environment and internal milestone names were generalized. The simulation runner is a new portable entry point around these existing tests. The original independent FIR example is retained as a separate numerical-verification exercise, not described as the FPGA data path.

Private protocol documents/photos, board topology, pin constraints, IP output products, hardware identities, bitstreams and historical raw evidence are excluded. [Architecture and source boundaries](docs/rtl-architecture.md) explains the interfaces and limitations. [Validation](docs/validation.md) distinguishes simulation from other evidence levels.

## 中文说明

从既有 FPGA 工程中整理通用数据通路及完整仿真依赖，展示帧校验、跨时钟域、复位、包边界切换、反压恢复与逐字验收。公开版可独立复现行为仿真；板级资源和厂商库由使用者在自己的合法工具环境中提供。开发过程使用 Codex 辅助实现和迭代。

## License

Repository-authored source: [MIT](LICENSE). External XPM, device primitives, tools and GitHub Actions retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md). The [FIR verification design](docs/verification-design.md) covers the numerical example.
