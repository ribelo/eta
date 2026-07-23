# Red team: least-trusted laws

The two least-trusted laws are cancellation claims because scheduler timing can
make a weak test pass without ever starting the work that is supposedly
cancelled.

## A. `par` fail-fast sibling cancellation

Attack shape: the sibling is `finally observable_cleanup never`; the failing
child yields/delays before failing so the sibling is genuinely pending. The
property must preserve the typed failure, observe exactly one cleanup event, and
report no pending structured fiber after `par` returns. Events after the first
failure are allowed when they belong to cancellation-protected cleanup.

Verdict: **PASS on the unchanged production implementation**. Fifty generated
failure payload/delay cases each preserved the first typed failure, emitted the
sibling finalizer exactly once, and left `pending_fibers = Some []`.

## B. Semaphore blocked-waiter cancellation

Attack shape: hold the sole permit, race a second acquisition against a delayed
winner, then inspect `waiting`, `cancelled_waiters`, and `available` before and
after releasing the original permit. The property must prove that the cancelled
waiter was removed and never consumed the permit; it does not claim fairness for
fibers that have not enqueued.

Verdict: **PASS on the unchanged production implementation**. Fifty generated
capacity/delay cases each observed one cancelled waiter, zero waiters and zero
available permits while the original permits remained held, then all permits
available after the explicit release.

Command:

```text
XDG_CACHE_HOME=/tmp/pi-nix-cache nix develop -c dune runtest test/laws --force
```

The complete suite passed 22 properties / 1,100 generated qcheck inputs. No
production violation was found. During construction, the scope-LIFO property
did find and shrink a **test bug** to resource list `[0; -1]`: the initial test
program acquired in reverse order, so its expected release order was invalid.
Changing construction to `List.fold_right` made acquisition follow input order;
the passing property now tests the intended law rather than encoding its answer.
