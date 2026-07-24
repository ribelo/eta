# DX-E27 review questions

1. **When does the format run?**
   The formatter closure runs once, while the effect is running, after logging
   is enabled and the scoped minimum admits the level. Built-in conversions,
   `%a`/`%t` printers, and other work inside it do not run for a filtered record.
   An interceptor may still `Drop` the formed record after formatting.
2. **What about the arguments?**
   Work inside the closure is deferred:
   `Effect.logf (fun fmt -> Format.fprintf fmt "len %d" (Queue.length q))` does
   not call `Queue.length` until admission. Work performed before `logf` remains
   eager as usual.
3. **What does the blueprint retain?**
   It retains values captured by the formatter closure for its lifetime. A
   filtered blueprint forms no body string or record, but its closure captures
   remain live while the blueprint remains live.
