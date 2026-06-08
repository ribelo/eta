# Graph Query API Results

Status: lab closed for implementation planning.

## Probe Ledger

| Probe | Status | Evidence |
| --- | --- | --- |
| P-Gqa-1 coverage across ten queries | Complete | p_gqa_1.log; coverage_matrix.md |
| P-Gqa-2 pattern composition expressiveness | Complete | p_gqa_2.log; pattern_features.md |
| P-Gqa-3 schema PPX for Node/Rel records | Partial | p_gqa_3.log; p_gqa_3_notes.md |
| P-Gqa-4 Cypher literal PPX feasibility | Partial | p_gqa_4.log; p_gqa_4_notes.md |
| P-Gqa-5 heterogeneous result decoder | Complete | p_gqa_5.log; p_gqa_5_notes.md |
| P-Gqa-6 parameter binding ergonomics | Partial | p_gqa_6.log; param_ergonomics.md |

## Candidate Verdicts

| Candidate | Verdict | Reason |
| --- | --- | --- |
| A - pure typed SQL-style pipe builder | Deferred / dominated for primary surface | Only 3 Clean cells; variable-length paths and bulk ingest need escape hatches. It is useful evidence that SQL's pipe shape does not transfer directly. |
| B - hybrid pattern DSL plus pipeable clauses | Survives | 8 Clean, 2 Awkward in P-Gqa-1; covers all pattern features in P-Gqa-2. Best typed authoring candidate. |
| C - Cypher literal PPX | Partial / not primary for v0.1 | Call-site is compact, but P-Gqa-4 shows useful validation stops at parameter/schema lint. Return-shape inference needs a real parser or metadata. |
| D - parameterized string plus typed decoder | Survives baseline | 10 Clean cells. Lowest implementation risk and always available escape hatch. |
| E - named pattern fragments plus raw Cypher clauses | Surprise survivor | 8 Clean, 2 Awkward. Often cleaner than a fully-general builder for app-owned recurring graph shapes. |

## Recommendation

Use a two-layer v0.1 surface:

1. Primary guaranteed surface: Branch D.
   - Graph.query conn ~cypher ~params ~decode
   - explicit parameters
   - tuple decoder primary
   - generated-record decoder optional when schema/aliases justify it

2. Typed ergonomic layer: Branch B, scoped to read queries and common patterns.
   - Pattern DSL for graph-shaped MATCH/OPTIONAL MATCH/path fragments
   - pipeable clause builder for WHERE/WITH/RETURN/ORDER/LIMIT
   - no attempt to force all Cypher writes into the builder

3. Optional app helper layer: Branch E.
   - named reusable pattern fragments
   - raw Cypher predicates/clauses as explicit escape hatches
   - useful for codebases with stable domain graph motifs

Do not ship Branch C literal PPX as a primary API in v0.1. A small parameter/schema lint PPX can be deferred, but return-shape inference is not proven.

## Surprise Findings

- The SQL-style pipe builder failed specifically at graph-shaped pattern composition; the winning typed shape splits graph patterns from linear clauses.
- Branch E emerged during coverage probing and is often a more honest app-level abstraction than a universal builder.
- Generated result records help more for multi-column scalar/aliased returns than for simple RETURN p.
- Literal PPX without a real parser is useful only as lint, not as a typed query surface.

## Not Measured

- Real ppxlib implementation.
- Compile-time negative tests for pattern misuse or param mismatch.
- Runtime execution against LadybugDB for these rendered Cypher queries.
- Full Cypher grammar coverage.
- REL/PATH Arrow decoding.
- Blob/bytes parameter binding, still blocked by the LadybugDB C API finding.

## Implementation-Ready Shape

Implementation can begin against adr.md. The implementation should start with Branch D plus decoders, then add the Branch B Pattern/Query builder only for the tested read-query subset.
