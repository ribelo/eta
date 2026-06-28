module type CAUSE = sig
  type 'err t

  val fail : 'err -> 'err t
  val die : string -> 'err t
  val interrupt : string option -> 'err t
  val concurrent : 'err t list -> 'err t
  val sequential : 'err t list -> 'err t
  val suppressed : primary:'err t -> finalizer:'err t -> 'err t
  val catch_fail : ('err -> 'a option) -> 'err t -> 'a option
  val pp : ('err -> string) -> 'err t -> string
  val otel_events : ('err -> string) -> 'err t -> (string * string) list
end

module Make (C : CAUSE) = struct
  type err =
    | Body
    | Finalizer
    | First
    | Second
    | Sibling
    | Tap
    | Typed

  let show_err = function
    | Body -> "Body"
    | Finalizer -> "Finalizer"
    | First -> "First"
    | Second -> "Second"
    | Sibling -> "Sibling"
    | Tap -> "Tap"
    | Typed -> "Typed"

  let par_two_failures () = C.concurrent [ C.fail First; C.fail Second ]

  let all_failure_plus_sibling_finalizer () =
    C.suppressed
      ~primary:(C.concurrent [ C.fail First; C.fail Sibling ])
      ~finalizer:(C.fail Finalizer)

  let nested_scoped_finalizer_during_failure () =
    C.suppressed
      ~primary:
        (C.suppressed ~primary:(C.fail Body)
           ~finalizer:(C.fail Finalizer))
      ~finalizer:(C.die "outer finalizer defect")

  let sequential_tap_rethrow () =
    C.sequential [ C.fail Typed; C.fail Tap ]

  let catch_single_fail () =
    C.catch_fail (function Typed -> Some "handled" | _ -> None) (C.fail Typed)

  let catch_concurrent_failure () =
    C.catch_fail
      (function First -> Some "wrong" | _ -> None)
      (par_two_failures ())

  let render_all () =
    [
      ("par_two_failures", par_two_failures ());
      ( "all_failure_plus_sibling_finalizer",
        all_failure_plus_sibling_finalizer () );
      ( "nested_scoped_finalizer_during_failure",
        nested_scoped_finalizer_during_failure () );
      ("sequential_tap_rethrow", sequential_tap_rethrow ());
    ]
    |> List.map (fun (name, cause) ->
           (name, C.pp show_err cause, C.otel_events show_err cause))
end
