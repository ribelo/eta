# H7 Null Probe

Status: final for Effet-OxCaml-rp2 T2.

Question: can a realistic CPU-bound Effet-shaped fan-out workload show useful
multi-domain speedup, disproving the single-domain-only hypothesis?

Command:

    nix develop .#oxcaml -c bash scratch/oxcaml_research/concurrency_model/h7_null_probe/run.sh

Output:

    single_domain wall_ms=44.814 count=80 work=36000000 checksum=229220960
    two_domain_parallel wall_ms=22.718 count=80 work=36000000 checksum=229220960
    h7_speedup=1.973

Evidence:

- The two-domain run produced the same count, work, and checksum as the
  single-domain run.
- Wall time improved from 44.814ms to 22.718ms on the same CPU fan-out
  workload, a 1.973x speedup.

Verdict: H7 is disproved. Multi-domain CPU fan-out matters for Effet; the
concurrency model must keep a domain-parallel runtime path.
