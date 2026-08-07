# Public Signal interface and graph ownership

Type: grilling
Status:
Blocked by: 17

## Question

Does the promoted execution model fit behind the current public Signal
interface, or does another interface create substantially more module depth?

Compare alternatives by caller knowledge, leverage, error modes, lifecycle
rules, performance characteristics, and testability. Do not preserve the
current interface through a compatibility adapter.

Decide the owner-domain and owner-fiber rules.
Decide whether map, bind, cutoff, and keyed builder functions can yield.
Compare separate public operations with fused, batch, and session operations.

Implement the selected interface directly in the production pre-alpha engine.
Run the complete behavior gate and each affected performance row.
