type error =
  [ `Unix of string * Unix.error * string
  | `End_of_file
  | `Short_read of int
  | `Message of string
  | `Parse of string ]

val pp_error : Format.formatter -> error -> unit

module Ids : sig
  type t = {
    bustype : int;
    vendor : int;
    product : int;
    version : int;
  }
end

module Event_type : sig
  type t =
    | Syn
    | Key
    | Rel
    | Abs
    | Msc
    | Sw
    | Led
    | Snd
    | Rep
    | Ff
    | Pwr
    | Ff_status
    | Unknown of int

  val of_int : int -> t
  val to_int : t -> int
  val to_string : t -> string
end

module Event : sig
  type t = {
    sec : int64;
    usec : int64;
    event_type : Event_type.t;
    code : int;
    value : int;
  }

  val of_raw :
    sec:int64 -> usec:int64 -> event_type:int -> code:int -> value:int -> t
end

module Abs_info : sig
  type t = {
    value : int;
    minimum : int;
    maximum : int;
    fuzz : int;
    flat : int;
    resolution : int;
  }
end

module Code : sig
  module Ev : sig
    val syn : int
    val key : int
    val rel : int
    val abs : int
  end

  module Syn : sig
    val report : int
  end

  module Rel : sig
    val x : int
    val y : int
    val wheel : int
    val hwheel : int
    val wheel_hi_res : int
    val hwheel_hi_res : int
  end

  module Abs : sig
    val x : int
    val y : int
    val z : int
    val rx : int
    val ry : int
    val rz : int
    val hat0x : int
    val hat0y : int
  end

  module Key : sig
    val esc : int
    val backspace : int
    val enter : int
    val leftctrl : int
    val leftshift : int
    val leftalt : int
    val leftmeta : int
    val space : int
    val pageup : int
    val pagedown : int
    val home : int
    val end_ : int
    val up : int
    val down : int
    val left : int
    val right : int
    val a : int
    val c : int
    val d : int
    val h : int
    val j : int
    val k : int
    val l : int
    val return : int
    val s : int
    val v : int
    val x : int
    val y : int
    val z : int

    val btn_south : int
    val btn_east : int
    val btn_north : int
    val btn_west : int
    val btn_tl : int
    val btn_tr : int
    val btn_tl2 : int
    val btn_tr2 : int
    val btn_select : int
    val btn_start : int
    val btn_mode : int
    val btn_thumbl : int
    val btn_thumbr : int
    val btn_dpad_up : int
    val btn_dpad_down : int
    val btn_dpad_left : int
    val btn_dpad_right : int
  end
end

module Device : sig
  type t

  val open_path : ?read_write:bool -> string -> (t, error) result
  val close : t -> unit
  val path : t -> string
  val fd : t -> Unix.file_descr
  val name : t -> (string, error) result
  val ids : t -> (Ids.t, error) result
  val abs_info : t -> code:int -> (Abs_info.t, error) result
  val grab : t -> (unit, error) result
  val ungrab : t -> (unit, error) result
  val read_event : t -> (Event.t, error) result

  val read_event_effect :
    ?pool:Eta_blocking.Pool.t -> t -> (Event.t, error) Eta.Effect.t
end

module Proc_devices : sig
  type entry = {
    ids : Ids.t option;
    name : string option;
    phys : string option;
    sysfs : string option;
    uniq : string option;
    handlers : string list;
    bits : (string * string) list;
  }

  val parse : string -> (entry list, error) result
  val load : ?path:string -> unit -> (entry list, error) result
  val event_handlers : entry -> string list
  val event_paths : ?dev_input_dir:string -> entry -> string list
  val matches_id : vendor:int -> ?product:int -> entry -> bool
end

module Uinput : sig
  type t

  val create :
    ?path:string ->
    ?name:string ->
    ?id:Ids.t ->
    ?keys:int list ->
    ?rel_axes:int list ->
    unit ->
    (t, error) result

  val close : t -> unit
  val emit : t -> event_type:Event_type.t -> code:int -> value:int -> (unit, error) result
  val sync : t -> (unit, error) result
  val key : t -> code:int -> pressed:bool -> (unit, error) result
  val rel : t -> code:int -> value:int -> (unit, error) result
end
