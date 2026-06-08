# Mainline CPU pool capture policy

Design A deliberately uses normal OCaml callbacks. That is the simplicity
baseline, but it means the compiler does not reject captures that are unsafe or
unwanted for domain workers.

The following mistakes are policy errors only in Design A:

- Capturing a mutable ref and mutating it from multiple worker domains.
- Capturing Eio.Stream.t and calling Eio.Stream.add from worker domains.
- Capturing Effet.Runtime.t and calling Runtime.run from worker domains.
- Capturing an in-memory Logger collector and dumping or mutating it from worker
  domains.

Design A can document these as forbidden, but it cannot make the compiler
enforce the rule. Design B's negative fixtures use this list as the target
sheet.
