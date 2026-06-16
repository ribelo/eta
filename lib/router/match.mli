(** A successful match from {!Router.at}. *)

type 'a t = {
  value : 'a;
  params : Params.t;
}
