# H-W4 decision rubric

Type: grilling
Status: resolved
Blocked by:

## Question

Decide the written rubric that every candidate ticket in this map applies
when it judges wrap, bridge, recipe, or reject.

The rubric must answer:

- When does a repeated consumer pattern earn an Eta wrapper? Start from the
  H-W4 invariant list: typed failure preservation, cancellation cleanup,
  scoped lifecycle, close fences, backpressure ownership, mode and
  portability fences, and runtime observability.
- When is the answer a `from_eio_X` bridge that exposes Eio directly?
- When is the answer a documented recipe instead of code?
- When is the answer rejection, and what records the rejection?
- What weight does "N consumers reinvented it" carry? The digest warns that
  reinvention alone is not proof.
- How does the rubric pick a package home under the package boundary policy?
- Does the rubric differ between boundary APIs and ergonomics APIs?

Use `$codebase-design` for the deep-module test: a good wrapper owns an
invariant, and a shallow wrapper only adds vocabulary.

## Answer

This is the rubric. Every candidate ticket in this map applies it.

### Two standing principles

Eta can be complex inside to keep the outside simple. Eta prefers deep
modules: much behavior behind a small interface.

Eta must also reduce the number of ways to do one job. An improvement that
adds a second way to do an existing job is not an improvement.

### Step 1: pick the branch

The rubric has two branches.

- The **Eio branch** applies when the candidate wraps an Eio primitive or
  another external library. H-W4 stays as AGENTS.md states it.
- The **surface branch** applies when the candidate wraps nothing external.
  Examples are a missing `pp`, a hidden `to_string`, or sugar over Eta's own
  API.

Both branches use the same tests and the same verdict set.

### Step 2: apply both tests

A `wrap` verdict needs both tests to pass.

- The **invariant test**: name one Eta-owned invariant that callers must
  reimplement without the candidate. The H-W4 list is the source: typed
  failure preservation, cancellation cleanup, scoped lifecycle, close fences,
  backpressure ownership, mode and portability fences, and runtime
  observability.
- The **deletion test**: delete the candidate. If complexity reappears at
  several call sites, the candidate earns its place. If the complexity
  vanishes, the candidate is a pass-through.

If the deletion test passes and the invariant test fails, the verdict is not
automatically `recipe`. Go to step 4 first.

### Step 3: apply the boundary bar or the ergonomics bar

A **boundary API** crosses between the effect world and the host world. It
gets the lower bar for `wrap`, because a door owns cause fidelity and exit
rendering. The evidence shows consumers lose that invariant:
`failwith "effect failed"`, the `<typed failure>` render, and the reset of
`Effect.fresh` identity under runtime-per-call.

An **ergonomics API** shortens a repeated pattern inside the effect world. It
gets the higher bar. Line count alone does not earn code.

### Step 4: the depth gate on `recipe`

A `recipe` verdict is legal only when the candidate cannot be deep. That is
true only when the caller must supply project policy that Eta cannot know.

If Eta can hold the complexity behind a smaller interface, the verdict is
`wrap` or `complete`, even without an H-W4 invariant. "We did not want to
write the code" is not a recipe.

### Step 5: choose one of six verdicts

| Verdict | Trigger |
| --- | --- |
| `wrap` | Both tests pass, and Eta owns the invariant or the depth. |
| `bridge` | Eio or the host type is the right interface. Eta adds a `from_eio_X` door and owns nothing more. |
| `recipe` | The depth gate in step 4 blocks code. Eta documents the pattern. |
| `complete` | An existing Eta module has a hole: a missing `pp`, a hidden `to_string`, no `Map` or `Set`, or a type that forces `Obj.magic`. No new invariant. |
| `prune` | An existing API is a near-duplicate of another. Delete it or merge it. |
| `reject` | The job belongs to the consumer, or the candidate adds a second way to do one job. |

### Step 6: run the prune check

Every `wrap`, `complete`, or `bridge` verdict must name the existing APIs it
makes redundant. Then it must prune them in the same decision, or state why
they stay. An empty prune list is a valid answer, but the check is not
optional.

### Step 7: pick the package home

Ask these three questions in this order.

1. Does the candidate need a dependency that the root `eta` package does not
   already have? If yes, the home is `eta_<feature>`.
2. Does the candidate name a host or a platform, for example Eio, jsoo, or
   HTTP? If yes, the home is that platform package.
3. Otherwise the home is the module in `lib/eta/` that owns the type the
   candidate touches.

A new package needs two or more candidate APIs. One API alone joins an
existing package.

### Weight of reinvention evidence

The count of consumers that reinvented a pattern is evidence of demand only.
It is never sufficient and never necessary for a verdict. It sets priority.

One sub-rule is recorded in the ticket record: when independent reinventions
**disagree**, the interface fails to teach the right answer. The 25-case
error mapper in nema against the substring match on cause text in inn is the
example. Divergence raises priority, and it separates a missing invariant
from a missing shortcut.

### Where a `reject` or a `prune` is recorded

The ticket answer holds the decision. For a reject that consumers keep
re-asking for, add one line to `docs/api-dx.md` so the answer is
discoverable in the repo. This map does not open a second decision store.

### The required record per candidate

Each candidate ticket emits these eight fields per candidate.

1. Name.
2. Verdict, one of the six.
3. Named invariant, or "none".
4. Deletion-test result.
5. Package home.
6. Prune list, which can be empty.
7. Law-registry obligation: the named test plus the registry row, or "no
   law-bearing prose".
8. Shape sketch in `.mli` form.

Field 8 can point to a prototype asset instead of holding the sketch inline.
Ticket 11 assembles the handoff from these records.
