# PPX env research results

Positive:

~~~text
nix develop -c dune build .scratch/research/evidence/ppx_env_research
exit=0

nix develop -c dune exec .scratch/research/evidence/ppx_env_research/runtime_smoke.exe
exit=0
~~~

Negative probes:

~~~text
PPX_ENV_NEG=env_creep nix develop -c dune build .scratch/research/evidence/ppx_env_research/neg_b_env_creep.exe
File ".scratch/research/evidence/ppx_env_research/neg_b_env_creep.ml", line 8, characters 4-50:
8 |     (Auth.current_user auth ^ Db.query env#db "x")]
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: effet leaf body must use listed capabilities, not env directly
~~~

~~~text
PPX_ENV_NEG=duplicate_cap nix develop -c dune build .scratch/research/evidence/ppx_env_research/neg_b_duplicate_cap.exe
File ".scratch/research/evidence/ppx_env_research/neg_b_duplicate_cap.ml", lines 7-8, characters 2-29:
7 | ..[%effet.sync "bad.duplicate" ((auth : Auth.t), (auth : Auth.t))
8 |     (Auth.current_user auth)]
Error: duplicate capability binding: auth
~~~

~~~text
PPX_ENV_NEG=duplicate_env nix develop -c dune build .scratch/research/evidence/ppx_env_research/neg_d_duplicate_env.exe
File ".scratch/research/evidence/ppx_env_research/neg_d_duplicate_env.ml", line 7, characters 2-65:
7 |   [%effet.env { auth = (auth : Auth.t); auth = (auth : Auth.t) }]
      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Error: duplicate capability binding: auth
~~~

~~~text
PPX_ENV_NEG=value_restriction_raw nix develop -c dune build .scratch/research/evidence/ppx_env_research/neg_value_restriction_raw.exe
File ".scratch/research/evidence/ppx_env_research/neg_value_restriction_raw.ml", lines 10-13, characters 6-3:
10 | ......struct
11 |   let current_user =
12 |     Effect.sync "auth.current_user" (fun env -> Auth.current_user env#auth)
13 | end
Error: Signature mismatch:
       ...
       Values do not match:
         val current_user :
           (< auth : Auth.t; .. > as '_weak1, '_weak2, string) Effect.t
       is not included in
         val current_user : (< auth : Auth.t; .. >, string, string) Effect.t
~~~

Interface sizes:

| Candidate | Lines | Bytes |
|---|---:|---:|
| P-A raw env#cap | 12 | 368 |
| P-B ppx leaf | 15 | 429 |
| P-C capability profile | 18 | 576 |
| P-D env builder | 12 | 386 |

Readable expansion excerpt:

~~~ocaml
let current_user () =
  Effet.Effect.fn __POS__ __FUNCTION__
    (Effet.Effect.sync "auth.current_user"
       (fun __effet_env ->
          let auth = (__effet_env#auth : Auth.t) in Auth.current_user auth))
~~~

~~~ocaml
let env ~auth ~log =
  object method auth = (auth : Auth.t) method log = (log : Log.t) end
~~~
