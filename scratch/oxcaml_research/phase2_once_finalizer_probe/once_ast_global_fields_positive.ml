(* Candidate E: make the resource AST consuming, but use record fields with
   [global_] for normal payloads and [@@ once] only for release. This checks
   whether field modalities avoid the Pure-value extraction problem seen in the
   tuple-shaped consuming AST. *)

type ('env, 'err, 'a) t =
  | Pure : { many_ value : 'a } -> ('env, 'err, 'a) t
  | Acquire_release :
      {
        global_ acquire : ('env, 'err, 'a) t;
        release : 'a -> ('env, 'err, unit) t @@ once;
      }
      -> ('env, 'err, 'a) t

let pure value = Pure { value }
let acquire_release ~acquire ~release = Acquire_release { acquire; release }

let rec run : type env err a. (env, err, a) t @ once -> a = function
  | Pure { value } -> value
  | Acquire_release { acquire; release } ->
      let value = run acquire in
      ignore (run (release value));
      value

let () =
  let released = ref false in
  let (release @ once) _ =
    released := true;
    pure ()
  in
  let value = run (acquire_release ~acquire:(pure 1) ~release) in
  if value <> 1 || not !released then failwith "once resource did not run"
