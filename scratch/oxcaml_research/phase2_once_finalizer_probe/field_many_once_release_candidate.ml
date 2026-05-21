(* Candidate D: keep the effect fields many while making only the release
   callback once. This tests whether constructor-field modalities can express
   the Phase 2 resource protocol without making the whole AST one-shot. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Acquire_release :
      {
        global_ acquire : ('env, 'err, 'a) t;
        release : 'a -> ('env, 'err, unit) t @@ once;
      }
      -> ('env, 'err, 'a) t

let acquire_release ~acquire ~release = Acquire_release { acquire; release }

let rec run : type env err a. (env, err, a) t -> a = function
  | Pure value -> value
  | Acquire_release { acquire; release } ->
      let value = run acquire in
      ignore (run (release value));
      value

let program =
  let (release @ once) _ = Pure () in
  acquire_release ~acquire:(Pure 1) ~release

let () =
  let a = run program in
  let b = run program in
  if a + b <> 2 then failwith "unexpected result"
