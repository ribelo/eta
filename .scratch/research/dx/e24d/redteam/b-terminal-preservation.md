# Red-team B — Terminal composites are not collapsed

**Verdict: PASS.**

Named executables:

- `retry composite rejection preserves original cause`
- `retry composite exhaustion preserves original cause`

Both use two typed failures. The rejection case proves that `while_` inspects
only the first failure and that the schedule is not stepped. The exhaustion
case retries one composite and then exhausts on a differently ordered terminal
composite; both policy inputs are checked, and the result must equal the second
tree using `Cause.equal`.

The selected failure drives policy only. It does not replace the terminal
diagnostic, so neither sibling failure is lost.
