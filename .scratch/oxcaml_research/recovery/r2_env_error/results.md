# R2 Portable Env/Error Boundary Results

Question: what public env and error shapes should the portable Effect core
accept, given that same-domain Effet can keep object rows and open polymorphic
variants?

## Env Candidates

| Candidate | Steelman | Evidence | Status |
| --- | --- | --- | --- |
| A. Closed record-of-capabilities | Compiler-checkable, named, easy to document, and works for both pure data and portable atomic tokens. | env_a_closed_records_positive ran the portable effect across Parallel_scheduler. | Accepted. |
| B. Phantom-tagged tuple | More extensible while staying within portable modes. | env_b_phantom_tuple_positive ran across Parallel_scheduler. | Dominated: no safety win over records, more public ceremony. |
| C. Closed object env | Closest to the existing same-domain object-row idiom. | env_c_closed_object_negative failed: object env kind was value mod global many non_float, not value mod portable contended. | Rejected. |

## Error Candidates

| Candidate | Steelman | Evidence | Status |
| --- | --- | --- | --- |
| A. Closed polymorphic variants only | Preserves familiar Effet typed-error style if the row is fully closed. | error_a_closed_polyvariant_positive compiled and ran. Open row negative failed with kind value mod non_float, not portable. | Allowed only when fully closed; not the canonical portable API style. |
| B. Named closed records/ordinary variants | Keeps typed errors, avoids row widening, and makes lifting explicit. | error_b_closed_record_positive compiled and ran with Catch. | Accepted as canonical. |
| C. Cause.Portable.t only | Simplest crossing boundary and already known portable. | error_c_cause_portable_positive compiled and ran, but reported typed_channel=false. | Dominated for user typed errors; reserved for runtime failure snapshots. |

## Negative Fixtures

- negative_open_polyvariant_error failed at the portable boundary.
- negative_raw_cause_error failed when raw same-domain Cause.t crossed Parallel.
- negative_ref_capture failed because a portable callback captured a mutable ref.

## Verdict

Portable envs use named closed records. A capability field may itself be
immutable data or a portable contended token, such as a Portable.Atomic-backed
random token. Portable envs do not use object methods or row-polymorphic object
types.

Portable typed errors use named closed records/ordinary variants with explicit
lifting between error families. Fully closed polymorphic variants are
compiler-compatible, but the portable API must not encourage open-row widening.
Cause.Portable.t remains the runtime failure snapshot boundary, not the only
public typed-error channel.

Same-domain Effect.t documentation is excluded from this constraint and can keep
the current object-row/open-variant style.

## Command

nix develop -c bash scratch/oxcaml_research/recovery/r2_env_error/run.sh

Result: summary pass=9 fail=0.

