type error =
  [ `Unix of string * Unix.error * string
  | `End_of_file
  | `Short_read of int
  | `Message of string
  | `Parse of string ]

let pp_error ppf = function
  | `Unix (fn, err, arg) ->
      Format.fprintf ppf "%s(%s): %s" fn arg (Unix.error_message err)
  | `End_of_file -> Format.pp_print_string ppf "end of file"
  | `Short_read n -> Format.fprintf ppf "short evdev read: %d bytes" n
  | `Message msg -> Format.pp_print_string ppf msg
  | `Parse msg -> Format.fprintf ppf "parse error: %s" msg

let error_of_exn = function
  | Unix.Unix_error (err, fn, arg) -> `Unix (fn, err, arg)
  | End_of_file -> `End_of_file
  | Failure msg | Invalid_argument msg -> `Message msg
  | exn -> `Message (Printexc.to_string exn)

let protect f = try Ok (f ()) with exn -> Error (error_of_exn exn)

module Ids = struct
  type t = {
    bustype : int;
    vendor : int;
    product : int;
    version : int;
  }
end

module Event_type = struct
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

  let of_int = function
    | 0x00 -> Syn
    | 0x01 -> Key
    | 0x02 -> Rel
    | 0x03 -> Abs
    | 0x04 -> Msc
    | 0x05 -> Sw
    | 0x11 -> Led
    | 0x12 -> Snd
    | 0x14 -> Rep
    | 0x15 -> Ff
    | 0x16 -> Pwr
    | 0x17 -> Ff_status
    | n -> Unknown n

  let to_int = function
    | Syn -> 0x00
    | Key -> 0x01
    | Rel -> 0x02
    | Abs -> 0x03
    | Msc -> 0x04
    | Sw -> 0x05
    | Led -> 0x11
    | Snd -> 0x12
    | Rep -> 0x14
    | Ff -> 0x15
    | Pwr -> 0x16
    | Ff_status -> 0x17
    | Unknown n -> n

  let to_string = function
    | Syn -> "syn"
    | Key -> "key"
    | Rel -> "rel"
    | Abs -> "abs"
    | Msc -> "msc"
    | Sw -> "sw"
    | Led -> "led"
    | Snd -> "snd"
    | Rep -> "rep"
    | Ff -> "ff"
    | Pwr -> "pwr"
    | Ff_status -> "ff_status"
    | Unknown n -> Printf.sprintf "unknown:%d" n
end

module Event = struct
  type t = {
    sec : int64;
    usec : int64;
    event_type : Event_type.t;
    code : int;
    value : int;
  }

  let of_raw ~sec ~usec ~event_type ~code ~value =
    { sec; usec; event_type = Event_type.of_int event_type; code; value }
end

module Abs_info = struct
  type t = {
    value : int;
    minimum : int;
    maximum : int;
    fuzz : int;
    flat : int;
    resolution : int;
  }
end

module Code = struct
  module Ev = struct
    let syn = 0x00
    let key = 0x01
    let rel = 0x02
    let abs = 0x03
  end

  module Syn = struct
    let report = 0
  end

  module Rel = struct
    let x = 0x00
    let y = 0x01
    let hwheel = 0x06
    let wheel = 0x08
    let wheel_hi_res = 0x0b
    let hwheel_hi_res = 0x0c
  end

  module Abs = struct
    let x = 0x00
    let y = 0x01
    let z = 0x02
    let rx = 0x03
    let ry = 0x04
    let rz = 0x05
    let hat0x = 0x10
    let hat0y = 0x11
  end

  module Key = struct
    let esc = 1
    let backspace = 14
    let enter = 28
    let leftctrl = 29
    let a = 30
    let d = 32
    let h = 35
    let j = 36
    let k = 37
    let l = 38
    let leftshift = 42
    let z = 44
    let x = 45
    let c = 46
    let v = 47
    let s = 31
    let y = 21
    let leftalt = 56
    let space = 57
    let home = 102
    let up = 103
    let pageup = 104
    let left = 105
    let right = 106
    let end_ = 107
    let down = 108
    let pagedown = 109
    let leftmeta = 125
    let return = enter

    let btn_south = 0x130
    let btn_east = 0x131
    let btn_north = 0x133
    let btn_west = 0x134
    let btn_tl = 0x136
    let btn_tr = 0x137
    let btn_tl2 = 0x138
    let btn_tr2 = 0x139
    let btn_select = 0x13a
    let btn_start = 0x13b
    let btn_mode = 0x13c
    let btn_thumbl = 0x13d
    let btn_thumbr = 0x13e
    let btn_dpad_up = 0x220
    let btn_dpad_down = 0x221
    let btn_dpad_left = 0x222
    let btn_dpad_right = 0x223
  end
end

external stub_device_name : Unix.file_descr -> string
  = "eta_linux_input_device_name"

external stub_device_ids : Unix.file_descr -> int * int * int * int
  = "eta_linux_input_device_ids"

external stub_abs_info : Unix.file_descr -> int -> int * int * int * int * int * int
  = "eta_linux_input_abs_info"

external stub_grab : Unix.file_descr -> bool -> unit = "eta_linux_input_grab"

external stub_read_event : Unix.file_descr -> int64 * int64 * int * int * int
  = "eta_linux_input_read_event"

external stub_set_evbit : Unix.file_descr -> int -> unit
  = "eta_linux_input_uinput_set_evbit"

external stub_set_keybit : Unix.file_descr -> int -> unit
  = "eta_linux_input_uinput_set_keybit"

external stub_set_relbit : Unix.file_descr -> int -> unit
  = "eta_linux_input_uinput_set_relbit"

external stub_uinput_setup :
  Unix.file_descr -> string -> int * int * int * int -> unit
  = "eta_linux_input_uinput_setup"

external stub_uinput_destroy : Unix.file_descr -> unit
  = "eta_linux_input_uinput_destroy"

external stub_write_event : Unix.file_descr -> int -> int -> int -> unit
  = "eta_linux_input_write_event"

module Device = struct
  type t = {
    fd : Unix.file_descr;
    path : string;
  }

  let open_path ?(read_write = false) path =
    protect @@ fun () ->
    let access = if read_write then Unix.O_RDWR else Unix.O_RDONLY in
    { fd = Unix.openfile path [ access ] 0; path }

  let close t = Unix.close t.fd
  let path t = t.path
  let fd t = t.fd
  let name t = protect (fun () -> stub_device_name t.fd)

  let ids t =
    protect @@ fun () ->
    let bustype, vendor, product, version = stub_device_ids t.fd in
    { Ids.bustype; vendor; product; version }

  let abs_info t ~code =
    protect @@ fun () ->
    let value, minimum, maximum, fuzz, flat, resolution = stub_abs_info t.fd code in
    { Abs_info.value; minimum; maximum; fuzz; flat; resolution }

  let grab t = protect (fun () -> stub_grab t.fd true)
  let ungrab t = protect (fun () -> stub_grab t.fd false)

  let read_event t =
    protect @@ fun () ->
    let sec, usec, event_type, code, value = stub_read_event t.fd in
    Event.of_raw ~sec ~usec ~event_type ~code ~value

  let read_event_effect ?pool t =
    Eta_blocking.run_result ?pool ~name:"eta_linux_input.read_event" (fun () ->
        read_event t)
end

module Proc_devices = struct
  type entry = {
    ids : Ids.t option;
    name : string option;
    phys : string option;
    sysfs : string option;
    uniq : string option;
    handlers : string list;
    bits : (string * string) list;
  }

  type builder = {
    ids : Ids.t option;
    name : string option;
    phys : string option;
    sysfs : string option;
    uniq : string option;
    handlers : string list;
    bits : (string * string) list;
  }

  let empty : builder =
    {
      ids = None;
      name = None;
      phys = None;
      sysfs = None;
      uniq = None;
      handlers = [];
      bits = [];
    }

  let finish (b : builder) : entry =
    {
      ids = b.ids;
      name = b.name;
      phys = b.phys;
      sysfs = b.sysfs;
      uniq = b.uniq;
      handlers = List.rev b.handlers;
      bits = List.rev b.bits;
    }

  let trim = String.trim

  let starts_with ~prefix s =
    let plen = String.length prefix in
    String.length s >= plen && String.sub s 0 plen = prefix

  let drop_prefix ~prefix s =
    if starts_with ~prefix s then
      Some (String.sub s (String.length prefix) (String.length s - String.length prefix))
    else None

  let unquote s =
    let s = trim s in
    let len = String.length s in
    if len >= 2 && s.[0] = '"' && s.[len - 1] = '"' then
      String.sub s 1 (len - 2)
    else s

  let split_words s =
    s |> String.split_on_char ' ' |> List.filter (fun x -> x <> "")

  let parse_hex_field key fields =
    fields
    |> List.find_map (fun field ->
           match String.split_on_char '=' field with
           | [ k; v ] when k = key -> Some (int_of_string ("0x" ^ v))
           | _ -> None)

  let parse_ids payload =
    let fields = split_words payload in
    match
      ( parse_hex_field "Bus" fields,
        parse_hex_field "Vendor" fields,
        parse_hex_field "Product" fields,
        parse_hex_field "Version" fields )
    with
    | Some bustype, Some vendor, Some product, Some version ->
        Ok (Some { Ids.bustype; vendor; product; version })
    | _ -> Error (`Parse ("invalid input id line: " ^ payload))

  let parse_assignment prefix payload =
    match drop_prefix ~prefix payload with
    | Some value -> Some (trim value)
    | None -> None

  let parse_bits payload =
    match String.index_opt payload '=' with
    | None -> None
    | Some idx ->
        let key = String.sub payload 0 idx |> trim in
        let value =
          String.sub payload (idx + 1) (String.length payload - idx - 1) |> trim
        in
        Some (key, value)

  let apply_line b line =
    if String.length line < 3 || line.[1] <> ':' then Ok b
    else
      let tag = line.[0] in
      let payload = String.sub line 2 (String.length line - 2) |> trim in
      match tag with
      | 'I' -> (
          match parse_ids payload with
          | Ok ids -> Ok { b with ids }
          | Error _ as err -> err)
      | 'N' -> (
          match parse_assignment "Name=" payload with
          | Some value -> Ok { b with name = Some (unquote value) }
          | None -> Ok b)
      | 'P' -> (
          match parse_assignment "Phys=" payload with
          | Some value -> Ok { b with phys = Some value }
          | None -> Ok b)
      | 'S' -> (
          match parse_assignment "Sysfs=" payload with
          | Some value -> Ok { b with sysfs = Some value }
          | None -> Ok b)
      | 'U' -> (
          match parse_assignment "Uniq=" payload with
          | Some value -> Ok { b with uniq = Some value }
          | None -> Ok b)
      | 'H' -> (
          match parse_assignment "Handlers=" payload with
          | Some value ->
              Ok { b with handlers = List.rev (split_words value) @ b.handlers }
          | None -> Ok b)
      | 'B' -> (
          match parse_bits payload with
          | Some bit -> Ok { b with bits = bit :: b.bits }
          | None -> Ok b)
      | _ -> Ok b

  let parse content =
    let commit current acc =
      match current with
      | None -> Ok acc
      | Some b -> Ok (finish b :: acc)
    in
    let rec loop current acc = function
      | [] -> (
          match commit current acc with
          | Ok entries -> Ok (List.rev entries)
          | Error _ as err -> err)
      | line :: rest ->
          if trim line = "" then
            match commit current acc with
            | Ok acc -> loop None acc rest
            | Error _ as err -> err
          else
            let current = Option.value current ~default:empty in
            match apply_line current line with
            | Ok current -> loop (Some current) acc rest
            | Error _ as err -> err
    in
    loop None [] (String.split_on_char '\n' content)

  let load ?(path = "/proc/bus/input/devices") () =
    match protect (fun () -> In_channel.with_open_bin path In_channel.input_all) with
    | Ok content -> parse content
    | Error _ as err -> err

  let event_handlers (entry : entry) =
    List.filter (fun h -> starts_with ~prefix:"event" h) entry.handlers

  let event_paths ?(dev_input_dir = "/dev/input") (entry : entry) =
    List.map (Filename.concat dev_input_dir) (event_handlers entry)

  let matches_id ~vendor ?product (entry : entry) =
    match entry.ids with
    | None -> false
    | Some ids ->
        ids.vendor = vendor
        &&
        match product with
        | None -> true
        | Some product -> ids.product = product
end

module Uinput = struct
  type t = {
    fd : Unix.file_descr;
    path : string;
    mutable closed : bool;
  }

  let default_id = { Ids.bustype = 0x03; vendor = 0x1209; product = 0x4750; version = 1 }

  let close t =
    if not t.closed then (
      t.closed <- true;
      (try stub_uinput_destroy t.fd with _ -> ());
      Unix.close t.fd)

  let create ?(path = "/dev/uinput") ?(name = "eta-linux-input")
      ?(id = default_id) ?(keys = []) ?(rel_axes = []) () =
    match protect (fun () -> Unix.openfile path [ Unix.O_WRONLY; Unix.O_NONBLOCK ] 0) with
    | Error _ as err -> err
    | Ok fd -> (
        match
          protect @@ fun () ->
          if keys <> [] then (
            stub_set_evbit fd Code.Ev.key;
            List.iter (stub_set_keybit fd) keys);
          if rel_axes <> [] then (
            stub_set_evbit fd Code.Ev.rel;
            List.iter (stub_set_relbit fd) rel_axes);
          stub_uinput_setup fd name (id.bustype, id.vendor, id.product, id.version)
        with
        | Ok () -> Ok { fd; path; closed = false }
        | Error err ->
            (try Unix.close fd with _ -> ());
            Error err)

  let emit t ~event_type ~code ~value =
    protect (fun () -> stub_write_event t.fd (Event_type.to_int event_type) code value)

  let sync t = emit t ~event_type:Event_type.Syn ~code:Code.Syn.report ~value:0

  let key t ~code ~pressed =
    let value = if pressed then 1 else 0 in
    emit t ~event_type:Event_type.Key ~code ~value

  let rel t ~code ~value = emit t ~event_type:Event_type.Rel ~code ~value
end
