# E5 review questions — rank-2 escape, solve with and without the page

You are reviewing a user-support scenario. `w5-rigged.ml` is real-shaped
user code that does not compile; `error.txt` is the exact compiler output.
The author's intent is in the file's header comment: run a refresh inside a
nursery and keep a way to get its result later, from elsewhere in the
program.

## Phase 1 — without the page

Put `page-excerpt.md` aside. Using only `w5-rigged.ml` and `error.txt`:

1. In your own words: what is the compiler rejecting?
2. Fix the code so it compiles and still does what the author wants
   (the refresh runs; its result can reach the rest of the program).
   Write down your fix or sketch it precisely.
3. Note how long you spent and how confident you are (0–100%) that the fix
   is the one Eta intends — not just one the compiler accepts.

## Phase 2 — with the page

Now read `page-excerpt.md`.

4. Does your phase-1 fix match one of the page's two canonical fixes?
   If you changed your answer, say what the page gave you that the error
   text did not.
5. Rate the entry: could you have solved the task from the entry alone,
   without reading `supervisor.mli`?

## Closing question (pass bar)

6. Explain the rank-2 rationale in your own words: what is `'s`, why does
   every `scoped` block get a fresh one, and what disaster does the
   restriction prevent? One short paragraph, no quoting.
