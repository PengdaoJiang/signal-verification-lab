# RTL architecture and release boundaries

## Framed link

The local byte stream passes through a dual-clock FIFO into a two-lane framer. A reset synchronizer and synchronized arm level control each domain. The receive parser accumulates a bounded payload and releases it only after header, direction, sequence, length, CRC and available commit-space checks. Invalid frames do not become successful payload deliveries.

Configuration bundles must be held stable before arm and throughout the transaction. The synchronized one-bit arm is not a generic multi-bit CDC solution. Status counters are domain-owned; a real system must snapshot them safely before crossing clock domains.

The asynchronous FIFO uses the vendor XPM implementation, including reset-busy gating and a synchronized read-pointer occupancy view. `link_clock_oe` manages clock-forwarding enable transitions separately from protocol state and forces the output-enable owner toward high impedance on a safety event. Electrical pad/clock routing remains a board-integration concern.

## Finite streaming engine

`finite_stream_engine` owns a fixed source RAM and capture RAM in their respective user-clock domains. Management requests transfer atomically through `finite_stream_bridge`. Each transaction contains 64 words of 512 bits. The four 128-bit segments carry enable/start/end/empty/error metadata.

The transmit ready indication is not treated as a same-cycle data-valid qualifier. The engine advances an already transmitted word exactly once and halts/resumes without replaying it. Switching from another packet source is allowed only at a completed packet boundary, including packed segment edge cases.

Receive alignment accepts start-of-packet in each of the four segment positions, compacts the frame into capture words, handles terminal metadata and rejects corrupted accepted frames. Completion crosses domains through atomic handshakes. The DUT stores received data; the testbench supplies independent expected vectors and compares the capture.

## Included dependency closure

All repository-owned modules needed by the five testbench tops are included. The only RTL library dependencies are installed XPM and device primitives. `glbl.v` is loaded from the user's Vivado installation. No generated CMAC, GT, VIO, board wrapper, pin map or synthesis project is required for these behavior-level tests.

These are two distinct datapaths, not a claim that the framed two-lane interface is the production interface of the finite segmented engine. The latter is a bounded diagnostic client, not a completed production baseband adapter. Synthesizable source is not proof of place-and-route or physical timing.

## Source-derived versus new

The RTL and self-checking benches originate in an existing engineering project. The public copy generalizes names and provides a standalone simulation runner. The original project's source and historical evidence remain unchanged. The Python/C FIR is the initial independent public example and is separate from the extracted RTL.
