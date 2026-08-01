# Available diffable map sources

Type: research
Status: resolved
Blocked by: none

## Question

Where can Eta obtain an immutable ordered map with ancestry-aware symmetric
diff and a small dependency boundary?

Compare Base, Core, `Incr_map`, `Stdlib.Map`, standalone packages, and an
Eta-owned implementation. Use primary source code and package metadata.

## Answer

Base and Core provide the only complete existing implementation found. Their
map skips physically shared subtrees and documents a bound of
`min(O(k log n), O(n))` for maps separated by `k` persistent edits.

Core is not required because Base owns the implementation. Base is a complete
standard-library replacement with a larger dependency and comparator surface
than Eta needs.

`Incr_map` is an operator package over Core maps and Incremental. It is a
reference for the keyed signal operator, not a source for the map container.

`Stdlib.Map` preserves tree structure across edits but exposes no
ancestry-aware symmetric diff. The reviewed standalone packages expose no
equivalent contract for arbitrary ordered keys.

The source evidence supports an Eta-owned implementation. Eta can use the
published balancing algorithms and keep Base as a behavior and performance
oracle.

Research reports:

- [Source options](../../../../.scratch/research/eta-signal-keyed-map/source-options.md)
- [Eta-owned design feasibility](../../../../.scratch/research/eta-signal-keyed-map/owned-design.md)
