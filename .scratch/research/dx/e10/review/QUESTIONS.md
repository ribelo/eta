# Reviewer questions

Answer from the packet files only; do not consult the experiment report.

1. What does the sugar expand to? Write the expansion you believe
   `let%eta f x = body` and `let f x = body [@@eta.trace]` become.
2. Does the sugar change runtime behaviour, or only tracing / span naming?
3. In `module-*.ml`, is the expansion a form you would accept as a verbatim PR
   rewrite of the handwritten twin?
4. Between `let%eta` and `[@@eta.trace]`, which spelling (if either) would you
   keep, and why?
5. The underlying pattern (`Effect.fn __POS__ __FUNCTION__`) appears at 5 sites
   in this codebase. Would you reach for this sugar? Why?
