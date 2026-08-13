# Session replacement and bootstrap

Type: grilling
Status: open
Blocked by: 10

## Question

What happens when a serialized session attaches, closes, or is replaced?

Specify a bootstrap observation for every active value. Decide how replacement
gets current committed state without a new graph change or application replay.

Define order between old-session closure, permit settlement, fresh identity
registration, bootstrap delivery, new advancement, and post-commit work.

Specify races with commit, removal, delivery acknowledgment, root stop, root
crash, and capacity failure.
