type ('env, 'err, 'a) t =
  | Pure : 'a -> (_, _, 'a) t
  | Fail : 'err -> (_, 'err, _) t
  | Sync : string * ('env -> 'a) -> ('env, _, 'a) t
  | Async : string * ('env -> 'a) -> ('env, _, 'a) t
  | Bind :
      ('env, 'err, 'b) t * ('b -> ('env, 'err, 'a) t)
      -> ('env, 'err, 'a) t
  | Map : ('env, 'err, 'b) t * ('b -> 'a) -> ('env, 'err, 'a) t
  | Catch :
      ('env, 'err1, 'a) t * ('err1 -> ('env, 'err2, 'a) t)
      -> ('env, 'err2, 'a) t
  | Tap_error : ('env, 'err, 'a) t * ('err -> unit) -> ('env, 'err, 'a) t
  | Delay : Duration.t * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Timeout :
      Duration.t * ('env, 'err, 'a) t -> ('env, [> `Timeout ] as 'err, 'a) t
  | Concat : ('env, 'err, unit) t list -> ('env, 'err, unit) t
  | Race : ('env, 'err, 'a) t list -> ('env, 'err, 'a) t
  | Par :
      ('env, 'err, 'a) t * ('env, 'err, 'b) t
      -> ('env, 'err, 'a * 'b) t
  | All : ('env, 'err, 'a) t list -> ('env, 'err, 'a list) t
  | For_each_par :
      'x list * ('x -> ('env, 'err, 'a) t)
      -> ('env, 'err, 'a list) t
  | Detach : ('env, _, unit) t -> ('env, 'err, unit) t
  | Uninterruptible : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Repeat : ('env, 'err, unit) t * Schedule.t -> ('env, 'err, unit) t
  | Retry :
      ('env, 'err, 'a) t * Schedule.t * ('err -> bool)
      -> ('env, 'err, 'a) t
  | Acquire_release :
      ('env, 'err, 'a) t * ('a -> ('env, _, unit) t)
      -> ('env, 'err, 'a) t
  | Scoped : ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Named : string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Annotate : string * string * ('env, 'err, 'a) t -> ('env, 'err, 'a) t
  | Provide :
      'env_in * ('env_in, 'err, 'a) t -> ('env_out, 'err, 'a) t

let pure v = Pure v
let fail e = Fail e
let unit = Pure ()
let sync name f = Sync (name, f)
let async name f = Async (name, f)

let map f e = Map (e, f)
let bind k e = Bind (e, k)
let ( >>= ) e k = Bind (e, k)
let tap k e = Bind (e, fun a -> Map (k a, fun () -> a))
let seq next self = Concat [ self; next ]
let concat es = Concat es
let race es = Race es
let par a b = Par (a, b)
let all xs = All xs
let for_each_par xs f = For_each_par (xs, f)
let detach e = Detach e
let uninterruptible e = Uninterruptible e

let catch h e = Catch (e, h)
let tap_error f e = Tap_error (e, f)
let retry sch pred e = Retry (e, sch, pred)

let delay d e = Delay (d, e)
let timeout d e = Timeout (d, e)
let repeat sch e = Repeat (e, sch)

let acquire_release ~acquire ~release = Acquire_release (acquire, release)
let scoped e = Scoped e

let named name e = Named (name, e)
let annotate ~key ~value e = Annotate (key, value, e)
let provide env_in e = Provide (env_in, e)

let rec name : type env err a. (env, err, a) t -> string option = function
  | Named (n, _) -> Some n
  | Annotate (_, _, e) -> name e
  | _ -> None

let collect_names e =
  let rec walk : type env err a.
      string list -> (env, err, a) t -> string list =
   fun acc -> function
    | Pure _ -> acc
    | Fail _ -> acc
    | Sync (n, _) -> n :: acc
    | Async (n, _) -> n :: acc
    | Named (n, e) -> walk (n :: acc) e
    | Annotate (_, _, e) -> walk acc e
    | Map (e, _) -> walk acc e
    | Delay (_, e) -> walk acc e
    | Timeout (_, e) -> walk acc e
    | Tap_error (e, _) -> walk acc e
    | Repeat (e, _) -> walk acc e
    | Retry (e, _, _) -> walk acc e
    | Scoped e -> walk acc e
    | Acquire_release (acq, _) -> walk acc acq
    | Bind (e, _) -> walk acc e
    | Catch (e, _) -> walk acc e
    | Concat xs -> List.fold_left walk acc xs
    | Race xs -> List.fold_left walk acc xs
    | Par (a, b) -> walk (walk acc a) b
    | All xs -> List.fold_left walk acc xs
    | For_each_par _ -> acc
    | Detach e -> walk acc e
    | Uninterruptible e -> walk acc e
    | Provide (_, e) -> walk acc e
  in
  List.rev (walk [] e)
