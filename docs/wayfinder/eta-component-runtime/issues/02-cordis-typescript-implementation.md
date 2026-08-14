# Cordis TypeScript implementation

Type: research
Status: open
Blocked by:

## Question

What behavior does the Cordis TypeScript implementation provide, and where does
it differ from the paper?

Use `.reference/cordis` at commit
`8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4`. Read the core, loader, group,
include, and HMR packages with their tests. Trace effect disposal, component
state, dependency notification, isolation, interception, configuration
reconciliation, module invalidation, rollback, and error behavior.

Map each important behavior to a named source location and executable test.
Identify behavior that the paper specifies but the implementation lacks, and
implementation behavior that the paper does not specify. Do not treat
incidental TypeScript representation as an Eta requirement.

Write one cited report under
`.scratch/research/eta-component-runtime/`.
