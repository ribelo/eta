# DX-E16 report — Reader validation race

## Recommendation

**KILL the optional Reader package; retain Eta's no-`R` boundary.** The Reader
port is fully viable and gets its strongest advantages: a parameter-free main
program, one provide boundary, Reader-native syntax, leaf accessors, and a real
`local` substitution. It nevertheless loses the completed pre-registered race
**value-passing 3, Reader 0, tie 1** on criteria 1–4. The orchestrator's
comprehension review remains deliberately unscored here, but Reader can no longer
meet the promotion gate requiring a majority of 1–4 plus the review.

This is dominance on this experiment's observable criteria, not a claim that
Reader cannot work. Confidence is medium: the fixture is a real but shallow
service graph; a substantially deeper application graph could change the
parameter-threading result.

## Scope and source choice

The source is `examples/service_composition.ml`. The three suggested candidates
have at most two values supplied to their main program:

- `connection_pool.ml`: `opened`, `closed` (2);
- `cached_resource.ml`: `observed`, `source` (2);
- `service_composition.ml`: `clock`, `released` (2).

I selected the tied maximum with the richest shape: resource acquisition,
release, and two database lookups. To give Reader a fair multi-dependency race,
both ports externalize the example's embedded `alice`/`bob` pair as one `users`
configuration value without changing behavior. The baseline therefore has three
application dependencies: `clock`, `released`, and `users`. The fourth-dependency
probe adds an `audit` collaborator.

Per DX-E19, Eta-owned clock/logger/tracer/random overrides are not application
environment fields. The `clock` here is the original example's application
value used by `User_db`, not the Eio clock supplied to Eta's interpreter.

## Equivalent behavior

The focused executable runs both ports and compares results:

```text
race:alice@42,bob@42 both-released=true
```

The fourth-dependency and `local` probes also run:

```text
fourth-dependency:both-audited=true
local-redteam:alice@42,carol@42 both-released=true
```

Raw output: `race/artifacts/focused-gate.log`.

## Pre-registered measurements

### 1. Diff size and shape — VALUE-PASSING WINS

Raw census (`race/artifacts/line-counts.txt`):

```text
# Comparable-port line census
value_passing.ml total=55 nonblank_noncomment=45 service_before_run=33
reader_port.ml total=70 nonblank_noncomment=58 service_before_run=41
reader.ml total=18 nonblank_noncomment=14
reader.mli total=46 nonblank_noncomment=22
race_main.ml total=7 nonblank_noncomment=7
```

On directly comparable port files, Reader costs **+15 physical lines**, **+13
nonblank/non-comment lines**, and **+8 service lines before the runtime helper**.
That excludes the optional abstraction's additional 14 implementation lines and
22 nonblank/non-comment interface lines.

The structural diff is preserved verbatim at `race/artifacts/ports.diff`. The
extra port lines are not business behavior: they are the three-field `env`,
`with_user_db`'s Reader run bridge, `users`/`lookup` lifting, the Reader syntax
boundary, the environment literal, and `Reader.run`. Reader does remove three
parameters from `program`, its strongest result on this criterion, but does not
recover the surrounding machinery in this service.

### 2. Inferred types on hover — TIE

Raw `ocamlfind ocamlc -i` output is in
`race/artifacts/value-passing.inferred.txt` and
`race/artifacts/reader.inferred.txt`.

Value-passing:

```ocaml
val program :
  clock ->
  bool ref ->
  users ->
  (string * string, [> `Closed | `Invalid_user of string ]) Eta.Effect.t
```

Reader:

```ocaml
val program :
  env ->
  (string * string, [ `Closed | `Invalid_user of string ]) Eta.Effect.t
```

Reader is shorter and names the bundle; value-passing shows all dependencies
without navigating to `env`. Because `Reader.t` is the required manifest alias,
`ocamlc -i` expands it to an ordinary function rather than displaying a distinct
Reader type. The sealed rule explicitly scored that outcome as a tie. The
closed-vs-open polymorphic-variant detail is an inference consequence of the two
compositions, not an environment result.

### 3. Wrong environment/dependency construction — VALUE-PASSING WINS

Both negative fixtures define the same wrong three-field bundle whose `clock`
has `now_s` instead of `now_ms`. Both fail with exit 2.

Value-passing (`race/artifacts/wrong-value-passing.error.txt`):

```text
File ".scratch/research/dx/e16/race/negative/wrong_value_passing.ml", line 17, characters 32-41:
17 | let _must_not_compile = program bad.clock bad.released bad.users
                                     ^^^^^^^^^
Error: This expression has type "wrong_clock"
       but an expression was expected of type "Value_passing.clock"
```

Reader (`race/artifacts/wrong-reader.error.txt`):

```text
File ".scratch/research/dx/e16/race/negative/wrong_reader.ml", line 17, characters 39-46:
17 | let _must_not_compile = Reader.run bad program
                                            ^^^^^^^
Error: This expression has type
         "Reader_port.env ->
         (string * string, [ `Closed | `Invalid_user of string ])
         Eta.Effect.t"
       but an expression was expected of type
         "wrong_env -> ('a, 'b) Eta.Effect.t"
       Type "Reader_port.env" is not compatible with type "wrong_env"
```

Both reject invalid construction statically, but value-passing identifies the
wrong `clock` and its expected type. Reader reports incompatible whole
environments and does not identify which field is wrong. That is materially less
local and overturns the predicted tie.

### 4. Environment drift after a fourth dependency — VALUE-PASSING WINS

The Reader baseline environment has **3 fields**. With `audit`, it has **4**.
Both four-dependency variants compile, run, and prove two audit observations.
Raw diffs are `race/artifacts/value_passing-fourth.diff` and
`race/artifacts/reader_port-fourth.diff`.

Raw numstat and site census (`race/artifacts/fourth-dependency-summary.txt`):

```text
# Fourth-dependency changed-line and site census
10	4	.scratch/research/dx/e16/race/{value_passing.ml => drift/value_passing_4.ml}
10	2	.scratch/research/dx/e16/race/{reader_port.ml => drift/reader_port_4.ml}
value-passing: env_record_fields=0; changed_dependency_type_or_signature_sites=1 (program); changed_full_construction_sites=1 (program call); audit_leaf_sites=2; audit_state/check_support=5
Reader: env_record_fields=4; changed_env_type_sites=1 (audit field); changed_full_construction_sites=1 (env literal); audit_leaf_sites=2; audit_accessor_sites=1; audit_state/check_support=5
```

Counterevidence favorable to Reader: raw churn is slightly lower (**14 changed
lines vs 12**) and `program` plus its `Reader.run` call stay unchanged. Reader
really does isolate the orchestration signature from dependency growth.

The pre-registered blob test concerns dependency-specific shape, however. After
removing common audit behavior and assertions, value-passing changes the
`program` signature and its call (2 plumbing sites). Reader changes the env type,
its complete construction, and adds an accessor (3 plumbing sites); every full
env constructor is coupled to the new field. With only one constructor in this
fixture the cost is already visible. Value-passing therefore wins narrowly,
while Reader's stable main signature is the strongest counterevidence in the
whole race.

### 5. Reviewer comprehension — PENDING ORCHESTRATOR

The clean review files are:

- `race/value_passing.ml`
- `race/reader_port.ml`
- `race/reader.mli` and `race/reader.ml`

No executor score is assigned.

## Steelman: strongest case for Reader

### 1. It removes parameter threading

The Reader port gives this argument its best chance. `program` has no dependency
parameters, `with_user_db` supplies the same environment through the scoped
resource callback, access is at Reader leaves, and the fourth dependency leaves
`program` and `Reader.run env program` textually unchanged. This is real positive
evidence, not a strawman. It loses here because the shallow real graph needs more
environment/access/run machinery than the parameters it removes, but a deeper
graph remains the main unresolved risk to the no-`R` decision.

### 2. `local` provides lexical subtree substitution

The red-team probe uses actual `Reader.local`, changes only the second configured
user to `carol`, preserves the outer environment, and runs successfully. Its cost
is preserved in `race/artifacts/local-cost.txt` and the source under
`race/redteam/`.

The honesty result: value-passing uses one ordinary record update and passes the
result to the lookup. Reader needs `local`, a nested record update, and a helper
that delays `users` selection until inside the subtree. If `users` or `User_db`
has already been selected/captured, `local` cannot retroactively modify it; the
override must surround selection/acquisition. Reader's lexical substitution is
valid, but its timing boundary is another concept reviewers must trace.

## Prediction scoring

| Prediction | Actual | Score |
| --- | --- | --- |
| C1 value-passing, Reader at least +8 service lines | Value-passing; exactly +8 service lines | Correct |
| C2 Reader narrowly, but tie if alias expands | Alias expanded; tie | Correct conditional prediction |
| C3 tie | Value-passing diagnostic is materially more local | Miss |
| C4 value-passing | Value-passing narrowly; Reader has lower raw churn counterevidence | Correct |
| C5 value-passing | Orchestrator review pending | Unscored |
| Final KILL | Reader fails majority of 1–4 | Correct so far |

Completed measurement score: **3 / 4 criterion predictions**, with the external
review pending. The predicted final verdict survives without using the pending
review as evidence.

## Hypothesis ledger and evidence verdicts

| Candidate | Strongest positive evidence | Strongest negative evidence | Status |
| --- | --- | --- | --- |
| A — ordinary value passing | Smaller port; explicit hover type; field-local compiler error; fewer dependency-plumbing sites | Main signature/call change on dependency growth; explicit threading would grow in a deeper graph | **ACCEPT / retain** |
| B — optional Reader | Stable parameter-free `program`; lower raw fourth-dependency churn; working lexical `local` | +13 comparable code lines, +36 abstraction/interface lines, whole-env diagnostic, env construction/accessor coupling, `local` selection timing | **DOMINATED / KILL** |

### V-DX-E16-1 — retain no-`R`

- **Status:** ACCEPT.
- **Decision:** ordinary values remain Eta's application-dependency mechanism.
- **Evidence:** criteria 1, 3, and 4 plus all runnable fixtures.
- **Counterevidence:** Reader's stable main signature and successful `local`.
- **Remaining uncertainty:** one shallow service cannot model every deep graph.
- **Would change if:** a pre-registered deeper real service lets Reader win the
  measured majority and review without moving runtime services into the env.

### V-DX-E16-2 — do not promote Reader

- **Status:** DOMINATED / KILL.
- **Decision:** keep the Reader implementation only as branch evidence; do not
  publish it or move it into Eta packages.
- **Evidence:** 0 wins on criteria 1–4, against 3 value-passing wins and 1 tie.
- **Counterevidence:** the rival compiles, behaves identically, and demonstrates
  both of its strongest claimed advantages.
- **Confidence:** medium, because graph depth remains the principal external-validity limit.

## Verification

Focused race and all exact required gates passed:

```text
PASS  nix develop -c dune build --root .scratch/research/dx/e16/race race_main.exe drift/drift_main.exe redteam/local_main.exe
PASS  nix develop -c dune exec --root .scratch/research/dx/e16/race ./race_main.exe
PASS  nix develop -c dune exec --root .scratch/research/dx/e16/race ./drift/drift_main.exe
PASS  nix develop -c dune exec --root .scratch/research/dx/e16/race ./redteam/local_main.exe
PASS  nix develop -c dune build @install
PASS  nix develop -c dune runtest --force
PASS  nix develop -c eta-oxcaml-test-shipped
```

Full logs and concise status: `race/artifacts/gate-*.log` and
`race/artifacts/gate-results.txt`.

## Ports inline for review

### Value-passing port

```ocaml
open Eta

type error =
  [ `Closed
  | `Invalid_user of string ]

type clock = { now_ms : unit -> int }
type users = { first : string; second : string }

let pp_error ppf (error : error) =
  match error with
  | `Closed -> Format.pp_print_string ppf "closed"
  | `Invalid_user user -> Format.fprintf ppf "invalid user: %s" user

module User_db = struct
  type t = {
    clock : clock;
    released : bool ref;
  }

  let open_ clock released =
    Effect.sync_result (fun () -> Ok { clock; released })

  let close db = Effect.sync (fun () -> db.released := true)

  let lookup db user_id =
    Effect.sync_result (fun () ->
        if !(db.released) then Error `Closed
        else if String.equal user_id "" then Error (`Invalid_user "empty")
        else Ok (Printf.sprintf "%s@%d" user_id (db.clock.now_ms ())))
end

let with_user_db clock released =
  Effect.with_resource ~acquire:(User_db.open_ clock released)
    ~release:User_db.close

let program clock released users =
  let open Syntax in
  let@ db = with_user_db clock released in
  let* first = User_db.lookup db users.first in
  let+ second = User_db.lookup db users.second in
  (first, second)

let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let clock = { now_ms = (fun () -> 42) } in
  let users = { first = "alice"; second = "bob" } in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program clock released users) with
  | Exit.Ok result when !released -> result
  | Exit.Ok _ -> failwith "value-passing port did not release the database"
  | Exit.Error cause ->
      failwith (Format.asprintf "value-passing failed: %a" (Cause.pp pp_error) cause)
```

### Reader port

```ocaml
open Eta

type error =
  [ `Closed
  | `Invalid_user of string ]

type clock = { now_ms : unit -> int }
type users = { first : string; second : string }

type env = {
  clock : clock;
  released : bool ref;
  users : users;
}

let pp_error ppf (error : error) =
  match error with
  | `Closed -> Format.pp_print_string ppf "closed"
  | `Invalid_user user -> Format.fprintf ppf "invalid user: %s" user

module User_db = struct
  type t = {
    clock : clock;
    released : bool ref;
  }

  let open_ clock released =
    Effect.sync_result (fun () -> Ok { clock; released })

  let close db = Effect.sync (fun () -> db.released := true)

  let lookup db user_id =
    Effect.sync_result (fun () ->
        if !(db.released) then Error `Closed
        else if String.equal user_id "" then Error (`Invalid_user "empty")
        else Ok (Printf.sprintf "%s@%d" user_id (db.clock.now_ms ())))
end

let with_user_db body env =
  Effect.with_resource ~acquire:(User_db.open_ env.clock env.released)
    ~release:User_db.close (fun db -> Reader.run env (body db))

let users = Reader.map (fun env -> env.users) Reader.ask
let lookup db user_id = Reader.lift (User_db.lookup db user_id)

let program =
  let open Reader.Syntax in
  with_user_db @@ fun db ->
  let* users = users in
  let* first = lookup db users.first in
  let+ second = lookup db users.second in
  (first, second)

let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let env =
    {
      clock = { now_ms = (fun () -> 42) };
      released;
      users = { first = "alice"; second = "bob" };
    }
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (Reader.run env program) with
  | Exit.Ok result when !released -> result
  | Exit.Ok _ -> failwith "Reader port did not release the database"
  | Exit.Error cause ->
      failwith (Format.asprintf "Reader failed: %a" (Cause.pp pp_error) cause)
```

## Final state

The optional module remains only under `.scratch/research/dx/e16/race/`; no core
or install-surface file changed. The sealed journal and implementation history
agree: the rival was steelmanned, it worked, its strongest counterevidence is
recorded, and the promotion gate did not pass.

**E16 READY FOR REVIEW**
