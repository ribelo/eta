# I1 / H1 - Mainline OCaml CPU pool baseline

Date: 2026-05-22

## Verdict

H1 holds. A normal OCaml CPU pool can express the practical finite CPU-offload
use case with input-order results, bounded parallelism, typed errors, and no
Eio handles inside worker jobs.

This is a strong baseline, not a losing strawman.

## Apples-To-Apples Controls

- Workloads: parse/validate, schema decode, hash/checksum/compress.
- Items: 128 per workload.
- Parallelism: bounded at 2 worker domains.
- Result contract: input order.
- Error contract: result values with one typed error exercised per workload.
- Runtime integration: called under Eio_main.run; worker jobs do not receive or
  use Eio handles.

The fixture implements a tiny persistent two-domain pool in scratch. It uses
Domain.spawn inside the pool implementation, with alerts suppressed there
because this is the pool implementation point, not user callback code.

## Evidence

Command:

    nix develop -c bash scratch/oxcaml_research/portable_islands/run.sh

Latest output excerpt:

    baseline workload=parse_validate items=128 ok=127 typed_errors=1 bounded=2 wall_us=367 eio_contamination=false
    baseline workload=schema_decode items=128 ok=127 typed_errors=1 bounded=2 wall_us=159 eio_contamination=false
    baseline workload=hash_checksum_compress items=128 ok=127 typed_errors=1 bounded=2 wall_us=119 eio_contamination=false
    baseline ordered_results=true items=32 bounded=2

## Safety Gap

Design A cannot make the compiler reject bad captures. The policy note lists
the mistakes Design B must reject mechanically:

- mutable ref capture;
- Eio.Stream capture;
- Runtime.run capture;
- Logger collector capture.

That gap is the only reason Design B remains competitive with this baseline.
