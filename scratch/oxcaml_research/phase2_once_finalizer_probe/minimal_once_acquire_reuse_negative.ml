(* Candidate A: store the release callback itself at [once] mode in the
   resource AST node. This mirrors the desired public acquire_release
   signature, but the program value is then consumed by interpretation. *)

type ('env, 'err, 'a) t =
  | Pure : 'a -> ('env, 'err, 'a) t
  | Acquire_release :
      ('env, 'err, 'a) t * ('a -> ('env, 'err, unit) t) @@ once
      -> ('env, 'err, 'a) t

let acquire_release ~acquire ~release = Acquire_release (acquire, release)

let rec run : type env err a. (env, err, a) t -> a = function
  | Pure v -> v
  | Acquire_release (acquire, release) ->
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
