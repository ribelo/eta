# Integrated finalist proof

Type: prototype
Status: resolved
Blocked by: 04, 07, 08, 10

## Question

Does one integrated finalist satisfy the complete Signal behavior suite and the
performance acceptance matrix?

Wire the finalist through a throwaway alternative factory. Run the full model,
law, lifecycle, failure, timer, keyed, allocation, and wall-time evidence.

## Answer

The tested integrated finalist does not pass the complete acceptance matrix.

The throwaway alternative factory implements the complete Signal and Signal Map
interfaces. It uses the selected typed core, sparse rollback journal,
generation-safe slots, structural capsules, execution seam, and edge driver.

The finalist passes every generated behavior suite.
It passes 21 model tests, 64 lifecycle tests, and 40 generated properties.
It also passes the public, contract, stream, map, keyed, and negative gates.

Raw allocation passes every matched ceiling.
Dynamic and keyed raw wall time passes every matched row.

The complete public wall time fails all 11 workloads in all three process pairs.
The smallest public ratio is `20.859`.
The largest public ratio is `123210.750`.

The Eta-only edge matrix passes six of eight rows.
Dynamic-scope cleanup fails wall time in all three pairs.
Observer disposal fails wall time and allocation in all three pairs.

Reject this finalist for production selection.
Keep the implementation as input to the next finalist.

The implementation, full samples, process medians, behavior totals, and rejected
rows are in
[Integrated finalist proof](../../../../.scratch/research/eta-signal-execution-model/integrated-finalist-proof.md).
