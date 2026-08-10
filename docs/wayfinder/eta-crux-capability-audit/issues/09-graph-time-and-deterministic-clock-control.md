# Graph time and deterministic clock control

Type: grilling
Status: open
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need graph time and deterministic test-time control?

Check the claim that the graph has no clock, deadlines cannot wake the driver,
and the test handle cannot advance time. Compare three possible ownership
shapes:

- time as graph input with a driver-visible next deadline.
- time as a shell operation.
- time as an application-owned source or staged effect.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, clock ownership, wake protocol,
semantic laws, deterministic test controls, failure behavior, and migration
effects.
