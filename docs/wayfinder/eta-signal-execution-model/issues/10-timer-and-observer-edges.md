# Timer and observer edge protocols

Type: prototype
Status:
Blocked by: 01, 09

## Question

How must timer lifecycle and observer delivery cross the selected pure-kernel
seam?

Preserve commit ordering, callback order, retries, cancellation, disposal,
runtime provenance, and failure aggregation. Charge these protocols only to
passes that use them.
