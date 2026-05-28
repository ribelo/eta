# P-Turso-6 - Conflict Error Code Surface

Status: **Partial**

Evidence:
- build log: build.log
- error log: errors.log

The probe deliberately opened two BEGIN CONCURRENT transactions on the same
row. After connection A committed, connection B's update and commit both
returned:

- rc=1
- xrc=0
- msg=not an error

This does not distinguish conflict-needs-retry from generic SQL error via the
raw code surface. The v0.1 driver cannot honestly expose a precise
Turso-conflict variant from this evidence alone.

