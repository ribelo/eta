(* Structured JSON encoding of portable causes. Core stays JSON-free; this
   encoder lives in eta_otel where JSON already lives. *)

let die_to_yojson (die : Eta.Cause.Portable.die) : Yojson.Safe.t =
  `Assoc
    ([
       ("kind", `String "die");
       ("exn", `String die.kind);
       ("message", `String die.message);
     ]
    @ (match die.backtrace with
      | None -> []
      | Some backtrace -> [ ("backtrace", `String backtrace) ])
    @ (match die.span_name with
      | None -> []
      | Some name -> [ ("span", `String name) ])
    @
    match die.annotations with
    | [] -> []
    | annotations ->
        [
          ( "annotations",
            `List
              (List.map
                 (fun (key, value) -> `List [ `String key; `String value ])
                 annotations) );
        ])

let interrupt_to_yojson id =
  `Assoc
    [
      ("kind", `String "interrupt");
      ("id", match id with
              | None -> `Null
              | Some id -> `Int (Eta.Cause.interrupt_id_to_int id));
    ]

let rec finalizer_to_yojson (node : Eta.Cause.Portable.Finalizer.t) :
    Yojson.Safe.t =
  match node with
  | Fail message -> `Assoc [ ("kind", `String "fail"); ("message", `String message) ]
  | Die die -> die_to_yojson die
  | Interrupt id -> interrupt_to_yojson id
  | Sequential nodes ->
      `Assoc
        [
          ("kind", `String "sequential");
          ("causes", `List (List.map finalizer_to_yojson nodes));
        ]
  | Concurrent nodes ->
      `Assoc
        [
          ("kind", `String "concurrent");
          ("causes", `List (List.map finalizer_to_yojson nodes));
        ]
  | Finalizer inner ->
      `Assoc
        [ ("kind", `String "finalizer"); ("cause", finalizer_to_yojson inner) ]
  | Suppressed { primary; finalizer } ->
      `Assoc
        [
          ("kind", `String "suppressed");
          ("primary", finalizer_to_yojson primary);
          ("finalizer", finalizer_to_yojson finalizer);
        ]

let rec to_yojson err_to_yojson (cause : 'err Eta.Cause.Portable.t) :
    Yojson.Safe.t =
  match cause with
  | Fail err -> `Assoc [ ("kind", `String "fail"); ("error", err_to_yojson err) ]
  | Die die -> die_to_yojson die
  | Interrupt id -> interrupt_to_yojson id
  | Sequential nodes ->
      `Assoc
        [
          ("kind", `String "sequential");
          ("causes", `List (List.map (to_yojson err_to_yojson) nodes));
        ]
  | Concurrent nodes ->
      `Assoc
        [
          ("kind", `String "concurrent");
          ("causes", `List (List.map (to_yojson err_to_yojson) nodes));
        ]
  | Finalizer inner ->
      `Assoc
        [ ("kind", `String "finalizer"); ("cause", finalizer_to_yojson inner) ]
  | Suppressed { primary; finalizer } ->
      `Assoc
        [
          ("kind", `String "suppressed");
          ("primary", to_yojson err_to_yojson primary);
          ("finalizer", finalizer_to_yojson finalizer);
        ]

let to_string err_to_yojson cause =
  Yojson.Safe.to_string (to_yojson err_to_yojson cause)
