# Internal module ownership

Type: grilling
Status: open
Blocked by: 09, 10, 11, 12, 13

## Question

Which private modules and seams make the chosen Eta Signal design deep and
local?

Assign each transaction, phase, scheduling, demand, topology, observer, timer,
stream, keyed, diagnostic, and testing invariant to one module. Apply the
deletion test to wrappers and callback records. Keep a private seam only when it
owns an invariant or supports real variation.

Resolve F5, F6, and F14. Do not simplify by merging unrelated responsibilities
into one kernel file.
