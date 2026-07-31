# Test seams and harness API

Type: grilling
Status: open
Blocked by: 02

## Question

Confirm the seams at which these requirements are verified, and the harness API that exposes
them.

Proposed seams, highest first:

- **Synchronous store** in `eta_crux_test`, with no driver: cell transitions, command
  emission and resolution through ordered pending-command handles, scoped exhaustive
  assertions, per-cell first-in-first-out order.
- **Real-driver harness** with a manual clock: tick phase order, boot and shutdown ordering,
  subscription reconciliation, timer wake, crash teardown.
- **Adapter recording fake**: output-to-property and row binding, host event to action,
  capability-message forwarding.
- **Two-domain probe**: non-owner admission failure, owner-domain producer suspension, and
  driver wake.
- **Build gate**: the package-boundary obligations, verified by a dependency assertion folded
  into the shipped-package gate.

Open questions carried from the notes:

- The API for selecting the observed cell set used by exhaustive assertions.
- Whether the synchronous harness may settle the graph for output assertions, or whether all
  output assertions live in the real-driver harness.

Blocked by ticket 02 because the harness surface depends on whether one public API spans both
state backends.
