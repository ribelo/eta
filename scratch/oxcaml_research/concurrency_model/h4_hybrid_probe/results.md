# H4 Hybrid Probe

Status: deferred for Effet-OxCaml-rp2 T5.

H4 was conditional on an H3 pathology, especially severe skew or
head-of-line blocking. The H3 probe did not show a throughput pathology on the
H7 workload, and the only bounded-inbox finding was expected backpressure
surfacing, not silent head-of-line blocking.

Verdict: do not adopt hybrid steal-on-overload as the default model. Reopen H4
only after a shipped H3 implementation produces measured skew that explicit
coordinator assignment cannot correct.

