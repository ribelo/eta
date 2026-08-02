# Package and module boundaries

Type: grilling
Status: open
Blocked by: 04, 08, 10, 12, 14

## Question

Which final responsibilities belong in `eta_crux`, `eta_signal`, test support,
and concrete host packages?

Decide the package and dependency graph for:

- the public computation API and runtime driver.
- private or public `eta_signal` engine hooks.
- keyed `assoc` support.
- deterministic test harnesses.
- generic adapter support.
- the generic source producer and the optional Eta stream bridge.
- Sliml and later host adapters.
- optional PPX syntax, if retained.

Apply the repository's install-only-what-you-use rule. The root `eta` package
must not depend on Eta Crux. Do not split a package only to hide an internal
module. Keep renderer, FFI, test, and PPX dependencies out of ordinary Eta Crux
applications.
