## Summary

## Verification

- [ ] nix develop -c dune runtest --force
- [ ] nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/run.sh
- [ ] nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_caveats/run.sh

## H3 Invariants

For PRs touching runtime, scheduler, supervisor, stream, or exporter code,
cite the relevant invariant or write N/A with a reason.

- Inbox ownership:
- Task identity:
- Result ordering:
- Failure ordering:
- Cancellation:
- Failure payload:
- Timeout/clock:
- Observability:
- Eio non-leakage:
- Backpressure:
- Dispatch under skew:
- Random/jitter:
- Phase 8 transport:
