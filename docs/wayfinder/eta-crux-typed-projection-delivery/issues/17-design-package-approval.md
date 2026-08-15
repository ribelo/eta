# Design package approval

Type: grilling
Status: resolved
Blocked by: 16, 18

## Question

Does the user approve this package for implementation?

Present unresolved risks and the complete coherence-audit result. Record
approval, requested changes, or rejection.

The effort reaches its destination only after explicit user approval.

## Answer

The user approved the package for implementation without changes.

The complete coherence-audit result and the five unresolved risks were
presented. The user accepted the risks as policy choices already endorsed
elsewhere in the repository:

1. The breaking change lands with no compatibility paths.
2. Change 2 lands as one atomic semantic change with no intermediate green
   state that keeps output delivery.
3. Performance gates stay regression-only against recorded baselines. Task T0
   commits the baseline between change 1 and change 2.
4. The `int64` incarnation keeps a documented unsigned-decimal contract
   instead of a distinct type.
5. The deleted profiles stay deleted by omission. A future pull profile is a
   fresh effort.

Implementation is authorized in the planned order: change 1 (fallible
`Codec`), task T0 (baseline recording), change 2 (the atomic projection
replacement), change 3 (performance gates). Implementation itself stays
outside this map; it proceeds as ordinary gated engineering work per
[Implementation plan](15-implementation-plan.md).

The destination is reached. The map closes with no open tickets and no
remaining fog.
