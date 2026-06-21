(* Library form of the bridge probe: the channel core + both Stream variants,
   with no top-level side effects, so the encapsulation negatives can link
   against it. See f_bridge_round_trip.ml for the runnable round-trip demo. *)

module Channel = struct
  type ('o, 'od, 'i, 'id, 'e) t =
    | Done : 'od -> ('o, 'od, 'i, 'id, 'e) t
    | Fail : 'e -> ('o, 'od, 'i, 'id, 'e) t
    | Emit : 'o * ('o, 'od, 'i, 'id, 'e) t -> ('o, 'od, 'i, 'id, 'e) t
    | Read :
        ('i -> ('o, 'od, 'i, 'id, 'e) t)
        * ('id -> ('o, 'od, 'i, 'id, 'e) t)
        * ('e -> ('o, 'od, 'i, 'id, 'e) t)
        -> ('o, 'od, 'i, 'id, 'e) t
    | Compose :
        ('m, 'md, 'i, 'id, 'e) t * ('o, 'od, 'm, 'md, 'e) t
        -> ('o, 'od, 'i, 'id, 'e) t

  let rec source (xs : 'o list) (d : 'od) : ('o, 'od, _, _, 'e) t =
    match xs with [] -> Done d | x :: rest -> Emit (x, source rest d)

  let rec split_lines (carry : string) : (string, string, string, 'id, 'e) t =
    Read
      ( (fun chunk -> explode (carry ^ chunk)),
        (fun _ -> if carry = "" then Done "" else Done carry),
        fun e -> Fail e )

  and explode (buf : string) : (string, string, string, 'id, 'e) t =
    let len = String.length buf in
    let rec go start acc i =
      if i = len then emit_lines acc (split_lines (String.sub buf start (len - start)))
      else if buf.[i] = '\n' then
        go (i + 1) (String.sub buf start (i - start) :: acc) (i + 1)
      else go start acc (i + 1)
    in
    go 0 [] 0

  and emit_lines (rev : string list) (k : (string, string, string, 'id, 'e) t)
    : (string, string, string, 'id, 'e) t =
    match rev with [] -> k | x :: rest -> Emit (x, emit_lines rest k)

  let rec echo_terminal : type o e. unit -> (o, unit, o, o, e) t =
    fun () ->
      Read ((fun x -> Emit (x, echo_terminal ())),
            (fun last -> Emit (last, Done ())), fun e -> Fail e)

  let emit_terminal_as_last (type o i id e)
    (c : (o, o, i, id, e) t) : (o, unit, i, id, e) t =
    Compose (c, echo_terminal ())

  let rec step : type o od i id e.
      (o, od, i, id, e) t ->
      [ `Emit of o * (o, od, i, id, e) t | `Done of od | `Fail of e ] =
    fun c ->
      match c with
      | Emit (x, k) -> `Emit (x, k)
      | Done d -> `Done d
      | Fail e -> `Fail e
      | Read _ -> failwith "dangling read (no upstream)"
      | Compose (l, r) -> drive l r

  and drive : type o od m md i id e.
         (m, md, i, id, e) t -> (o, od, m, md, e) t ->
         [ `Emit of o * (o, od, i, id, e) t | `Done of od | `Fail of e ] =
    fun l r ->
      match r with
      | Emit (x, r') -> `Emit (x, Compose (l, r'))
      | Done d -> `Done d
      | Fail e -> `Fail e
      | Read (oe, od, of_) ->
          (match step l with
           | `Emit (mv, l') -> drive l' (oe mv)
           | `Done mdv -> drive (Done mdv) (od mdv)
           | `Fail e -> drive (Fail e) (of_ e))
      | Compose (l2, r2) -> step (Compose (Compose (l, l2), r2))

  let rec run_fold : type o od i id e acc.
      (acc -> o -> acc) -> acc -> (o, od, i, id, e) t -> (acc * od, e) result =
    fun f acc c ->
      match step c with
      | `Emit (o, k) -> run_fold f (f acc o) k
      | `Done d -> Ok (acc, d)
      | `Fail e -> Error e
end

module StreamA : sig
  type ('a, 'e) t
  val source : 'a list -> ('a, 'e) t
  val to_channel : ('a, 'e) t -> ('a, unit, unit, unit, 'e) Channel.t
  val of_channel : ('a, unit, unit, unit, 'e) Channel.t -> ('a, 'e) t
  val run_fold : ('acc -> 'a -> 'acc) -> 'acc -> ('a, 'e) t -> ('acc, 'e) result
end = struct
  type ('a, 'e) t = ('a, unit, unit, unit, 'e) Channel.t
  let source (xs : 'a list) : ('a, 'e) t = Channel.source xs ()
  let to_channel (c : ('a, 'e) t) : ('a, unit, unit, unit, 'e) Channel.t = c
  let of_channel (c : ('a, unit, unit, unit, 'e) Channel.t) : ('a, 'e) t = c
  let run_fold (f : 'acc -> 'a -> 'acc) (acc : 'acc) (c : ('a, 'e) t)
    : ('acc, 'e) result =
    match Channel.run_fold f acc c with Ok (a, ()) -> Ok a | Error e -> Error e
end

module StreamP : sig
  type ('a, 'e) t = private ('a, unit, unit, unit, 'e) Channel.t
  val source : 'a list -> ('a, 'e) t
  val of_channel : ('a, unit, unit, unit, 'e) Channel.t -> ('a, 'e) t
  val run_fold : ('acc -> 'a -> 'acc) -> 'acc -> ('a, 'e) t -> ('acc, 'e) result
end = struct
  type ('a, 'e) t = ('a, unit, unit, unit, 'e) Channel.t
  let source xs = Channel.source xs ()
  let of_channel (c : ('a, unit, unit, unit, 'e) Channel.t) : ('a, 'e) t = c
  let run_fold f acc c =
    match Channel.run_fold f acc c with Ok (a, ()) -> Ok a | Error e -> Error e
end
