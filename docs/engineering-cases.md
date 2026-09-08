# Engineering cases: packet boundaries, backpressure and acceptance

The cases below are implemented in the published RTL and self-checking benches. They are behavior-level regression evidence; the [validation record](validation.md) identifies which simulator and source scope were actually exercised.

## Corruption must not leak a partial payload

**Implementation:** [receive parser](../rtl/common/link_rx_parser.sv), [endpoint integration](../rtl/common/minimal_link_core.sv), [endpoint testbench](../tb/tb_link_endpoint.sv).

Receiving bytes is not enough to accept a frame. The parser accumulates a bounded payload and commits only after frame metadata, sequence, CRC and available capacity checks. The bench injects a payload-bit error and separately changes the expected sequence of an otherwise CRC-clean frame. Both must increment the corresponding error condition without delivering payload as successful data.

The tradeoff is bounded buffering before commit. This gives a clear acceptance boundary; it is not an arbitrary-length cut-through interface. Reset-abort coverage checks that a transaction does not resume merely because stale arm/configuration state survived elsewhere.

## A falling ready signal must not replay a word

**Implementation:** [finite engine](../rtl/finite/finite_stream_engine.sv), [finite-engine bench](../tb/tb_finite_stream_engine.sv).

The segmented interface has protocol-specific halt timing. A word already transmitted on the falling-ready cycle must be advanced exactly once. Treating ready as a generic same-cycle valid qualifier can repeat that word on resume.

The bench drops ready during active full-duplex transfers, checks the halt and resume cycles, then independently compares every captured word. Search for `CMAC_HALT_WITHDRAW`, `CMAC_HALT_RESUME_REPLAY` and the final capture comparisons. This connects a temporal control error to an observable data-integrity failure rather than accepting a completion bit alone.

## A bus-word boundary is not a packet boundary

**Implementation:** [finite engine](../rtl/finite/finite_stream_engine.sv), `drive_offset_packet_b` and takeover checks in [the bench](../tb/tb_finite_stream_engine.sv).

Four segments share a user word. An end-of-packet may be followed by a new packet in the same cycle; an enable-low gap may occur while a packet is still open. Taking ownership on either superficial signal can cut the previous producer's packet in half.

Takeover waits for a genuinely closed packet boundary. Receive tests start a packet at each segment offset, include an earlier packet ending in the same word, and check compaction against an external vector. Nonterminal metadata and terminal error rejection are exercised separately. The management [request/response bridge](../rtl/finite/finite_stream_bridge.sv) keeps command payloads atomic across domains.

## Run and inspect

```text
python scripts/run_rtl.py --vivado-bin PATH_TO_VIVADO/bin --out rtl-output
```

Use an installed compatible Vivado/XSim and a fresh output directory. Inspect per-bench logs together with `receipt.json`; the receipt binds results to the source files used. Hosted CI covers the portable numerical path, runner behavior and a vendor-independent CRC bench, while the full XPM simulation requires the installed vendor libraries. None of these checks establishes physical timing, RF performance or board-level CDC safety.
