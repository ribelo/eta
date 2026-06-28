# Results

Positive smoke:

~~~text
nix develop -c dune exec .scratch/research/evidence/r_followup_research/runtime_smoke.exe
exit=0
~~~

Negative probes:

~~~text
R_FOLLOWUP_NEG=black_box_value nix develop -c dune build .scratch/research/evidence/r_followup_research/neg_black_box_value.exe
File ".scratch/research/evidence/r_followup_research/neg_black_box_value.ml", lines 11-14, characters 6-3:
11 | ......struct
12 |   let black_box =
13 |     Effect.sync "third.black_box" (fun env -> query env#db "child")
14 | end
Error: Signature mismatch:
       ...
       Values do not match:
         val black_box :
           (< db : db; .. > as '_weak1, '_weak2, string) Effect.t
       is not included in
         val black_box : (< db : db; .. >, string, string) Effect.t
       The type (< db : db; .. > as '_weak1, '_weak2, string) Effect.t
       is not compatible with the type
         (< db : db; .. >, string, string) Effect.t
       Type '_weak1 is not compatible with type 'a
~~~

~~~text
R_FOLLOWUP_NEG=closed_row_extra_env nix develop -c dune build .scratch/research/evidence/r_followup_research/neg_closed_row_extra_env.exe
File ".scratch/research/evidence/r_followup_research/neg_closed_row_extra_env.ml", line 17, characters 28-62:
17 |   Services.run_with_env env Public_mli_styles.closed_row_value
                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: The value Public_mli_styles.closed_row_value has type
         (< clock : Services.clock; log : Services.log >, string, string)
         Effet.Effect.t
       but an expression was expected of type
         (< clock : Services.clock; log : Services.log;
            secret : Services.secret >,
          string, 'a)
         Effet.Effect.t
       The first object type has no method secret
~~~

~~~text
R_FOLLOWUP_NEG=evolution_env_missing_metric nix develop -c dune build .scratch/research/evidence/r_followup_research/neg_evolution_env_missing_metric.exe
File ".scratch/research/evidence/r_followup_research/neg_evolution_env_missing_metric.ml", line 14, characters 28-65:
14 |   Services.run_with_env env (Library_evolution.Env_row.V2.top ())
                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: This expression has type
         (< clock : Services.clock; metrics : Services.metrics; .. >, 'a,
          int)
         Effet.Effect.t
       but an expression was expected of type
         (< clock : Services.clock >, string, 'b) Effet.Effect.t
       The second object type has no method metrics
~~~

~~~text
R_FOLLOWUP_NEG=evolution_args_missing_metric nix develop -c dune build .scratch/research/evidence/r_followup_research/neg_evolution_args_missing_metric.exe
File ".scratch/research/evidence/r_followup_research/neg_evolution_args_missing_metric.ml", line 8, characters 2-58:
8 |   Library_evolution.Args.V2.top ~clock:(Services.clock 42)
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error (warning 5 [ignored-partial-application]): this function application is partial,
  maybe some arguments are missing.
~~~

Same-shape semantic collision:

~~~text
R_FOLLOWUP_NEG=hazard_same_shape_collision nix develop -c dune build .scratch/research/evidence/r_followup_research/hazard_same_shape_collision.exe
exit=0
~~~

Interface proxy:

~~~text
nix develop -c ocamlc -i -open R_followup_research \
  -I _build/default/packages/effet/.effet.objs/byte \
  -I _build/default/.scratch/research/evidence/r_followup_research/.r_followup_research.objs/byte \
  .scratch/research/evidence/r_followup_research/public_mli_styles.ml

val open_row_thunk :
  unit ->
  (< clock : R_followup_research.Services.clock;
     log : R_followup_research.Services.log; .. >,
   'a, string)
  Effet.Effect.t
val closed_row_value :
  (< clock : R_followup_research.Services.clock;
     log : R_followup_research.Services.log; .. >
   as '_weak1, '_weak2, string)
  Effet.Effect.t
val args :
  clock:R_followup_research.Services.clock ->
  log:R_followup_research.Services.log -> ('a, 'b, string) Effet.Effect.t
val bag :
  < clock : R_followup_research.Services.clock;
    log : R_followup_research.Services.log; .. > ->
  ('a, 'b, string) Effet.Effect.t
~~~
