# H5 Centralized-Orchestrator Probe

Status: deferred for Effet-OxCaml-rp2 T5.

H5 was conditional on an H3 pathology in supervisor failure ordering or
observability reassembly. The H3 probe returned portable failures and portable
events to the coordinator without requiring a single-domain orchestrator for
all evaluation.

Verdict: do not adopt centralized orchestrator plus pure fan-out as the default
model. Keep the coordinator responsible for dispatch and reassembly, but let
workers execute their assigned pure-core sub-effects.

