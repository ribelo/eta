module Response_idle_timeout = Eta_http.Request.Response_idle_timeout

let qcheck_seed = Random.State.make [| 0xE22; 0x4854_5450 |]
let count = 100

let nonpositive =
  QCheck.map
    (fun value -> if value = Int.min_int then value else -abs value)
    QCheck.int

let positive =
  QCheck.map
    (fun value -> if value = Int.max_int then value else value + 1)
    QCheck.int_pos

let property_response_idle_timeout_domain =
  QCheck.Test.make
    ~name:
      "response idle timeout rejects generated nonpositive milliseconds and round-trips generated positive milliseconds"
    ~count QCheck.(pair nonpositive positive)
    (fun (invalid, milliseconds) ->
      let rejects_invalid =
        match Response_idle_timeout.of_ms invalid with
        | _ -> false
        | exception Invalid_argument _ -> true
      in
      let round_trip =
        Response_idle_timeout.of_ms milliseconds
        |> Response_idle_timeout.to_ms
        |> Option.equal Int.equal (Some milliseconds)
      in
      rejects_invalid && round_trip)

let () =
  let code =
    QCheck_base_runner.run_tests ~colors:false ~verbose:true ~rand:qcheck_seed
      [ property_response_idle_timeout_domain ]
  in
  exit code
