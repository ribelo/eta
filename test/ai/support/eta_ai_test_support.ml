let read_fixture name =
  let path = Filename.concat "fixtures" name in
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let expect_ok label = function
  | Ok value -> value
  | Error _ -> Alcotest.fail ("expected Ok: " ^ label)

let expect_ok_msg label show_error = function
  | Ok value -> value
  | Error err ->
      Alcotest.failf "expected Ok: %s (%s)" label (show_error err)
