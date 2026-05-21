(* Candidate B isolated: a run argument annotated @ once does not by itself
   make an ordinary AST value linear. This compiles, so linearity would need
   to be carried by the AST representation itself, where the richer fixture
   once_ast_reuse_negative already runs into constructor/value mode friction. *)

type 'a t = Pure of 'a

let run (program @ once) =
  match program with
  | Pure _ -> ()

let ok () =
  let program = Pure 1 in
  run program;
  run program

let () = ok ()

