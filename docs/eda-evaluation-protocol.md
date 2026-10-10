# RTL tasks as verifiable evaluation records

This protocol organizes the existing implementation and self-checking benches into a
small, inspectable task catalog. It is an engineering evaluation seed, not a model
leaderboard, proprietary design dataset, or completed SFT/RL training campaign.

## Task anatomy and taxonomy

[The machine-readable catalog](../evaluation/task_catalog.json) binds each task to
a real runner case and diagnostic strings in its trusted testbench. It includes a
repair-task template, fixed evaluator rules, complexity tier, expected behavior,
oracle anchors and candidate failure labels.

| Family | Engineering challenge | Independent check |
|---|---|---|
| CRC datapath | Initialization and byte/bit ordering | Known-answer vector |
| Clock/reset control | Pulse integrity, safety stop and re-arm | Phase variation and stop/clear checks |
| Frame validation | Commit only after CRC/sequence validation | Injected corruption, sequence faults and reset |
| Multi-clock integration | Full-duplex data and accounting | Independent per-direction vectors and timeout |
| Segmented streaming | Packet ownership and halt/resume | Offset cases, independent capture, replay checks |

L1/L2/L3 describe engineering complexity, not measured model difficulty. Fault
labels are a review vocabulary; matching a diagnostic does not alone establish root
cause. Human-reviewed mutations or naturally occurring failures need their own
provenance and split policy before they become separate benchmark instances.

## Reproduce and export

Run from the repository root with a compatible installed Vivado/XSim:

```text
python scripts/run_rtl.py --vivado-bin PATH_TO_VIVADO/bin --out rtl-output
python evaluation/export_results.py --receipt-dir rtl-output --out rtl-results.jsonl
```

For a deliberately bounded run, supply the same case to both commands:

```text
python scripts/run_rtl.py --vivado-bin PATH_TO_VIVADO/bin --out crc-output --case tb_link_crc32c
python evaluation/export_results.py --receipt-dir crc-output --task tb_link_crc32c --out crc-results.jsonl
```

The exporter runs no simulator and never replaces an output dataset. Each JSONL row
binds the task/catalog, expected implementation, trusted bench, runner, Tcl script,
receipt and raw log. The default requested denominator includes every catalog task;
missing runs are retained as `unscorable`, not silently dropped. A source mismatch,
missing log, altered log, duplicate case or contradictory completion marker cannot
be exported as a passing sample.

The version-1 runner receipt only seals completed passing cases. It cannot tell
whether an absent case failed in the design, hit an environment error, timed out,
or was never selected. The exporter therefore emits only verified behavioral
successes (`outcome_reward = 1`) and explicit unscorable records (`null`). It does
not invent negative training labels or attribute infrastructure failure to a model.

## Keep the rubric layers distinct

1. **Tool execution:** the runner rejects nonzero tool exits. Its v1 receipt does
   not serialize every exit code, so the export's `tool_exit_codes` remains null.
2. **Behavioral outcome:** exact source/log bindings plus the trusted self-checking
   bench provide a scoped outcome. This is not proof against an adversary who can
   forge the entire evidence package.
3. **Process/milestones:** compile, diagnose, patch and revalidate are useful stages,
   but v1 receipts do not contain an agent operation trace. `process_reward` remains
   null. A separate collector must record observable tool actions, concise explicit
   explanations and artifact lineage; no hidden model reasoning is required.
4. **Physical metrics:** slack, area, power, CDC and DRC need an actual tool run with
   target, constraints and stage identity. Behavioral simulation provides none of
   these; `physical_metrics` remains null. A PPA reward must never override a failed
   correctness gate.
5. **Expert review:** an explanation-quality or maintainability judgment is separate
   from the hard outcome and should retain reviewer/rubric versions and disagreement.

The [Agent execution evidence kit](https://github.com/PengdaoJiang/agent-eval-evidence-kit)
contains a complementary trace collector and paired-experiment workflow. It is not
automatically wired into this runner. A [review workbench](https://github.com/PengdaoJiang/document-review-workbench)
demonstrates version-bound production, independent review and adjudication.

## Dataset safeguards

- Freeze trusted evaluator files outside a candidate's writable area. This exporter
  checks identity; it is not a sandbox or a security boundary for hostile RTL.
- Split by design/fault family before mutation or prompt expansion. Deduplicate by
  source and task identity; never distribute near-identical variants across splits.
- Public reference RTL and benches are visible. They are useful for reproducibility,
  but not a contamination-resistant hidden benchmark.
- Retain environment failures, unknown outcomes and disagreement. Any SFT examples,
  preference pairs or reward labels require an explicit downstream curation policy.
- Hosted CI tests the exporter's positive/negative behavior using **synthetic receipt
  fixtures**, alongside the existing real vendor-independent CRC simulation. Those
  fixtures are not model trajectories, fresh full-XSim results, or chip signoff.
