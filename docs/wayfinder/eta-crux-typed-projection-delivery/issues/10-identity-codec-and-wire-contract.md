# Identity, codec, and wire contract

Type: grilling
Status: open
Blocked by: 08, 09

## Question

How must static and dynamic identities, heterogeneous values, codecs, handles,
and serialized frames work?

Define identity continuity, collision rejection, removal and re-entry, codec
fixity, remote-handle scope, and cutoff behavior.

Define identity-binding observations and serialized frames. Specify frame-size
limits, batch capacity, encode failure, decode failure, write failure, adapter
rejection, and acknowledgment outcomes.

Make sure that the driver is the only transport writer and that the adapter
applies one batch atomically.
