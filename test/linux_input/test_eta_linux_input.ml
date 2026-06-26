open Eta_linux_input

let expect_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "expected Ok, got %a" pp_error err

let fixture =
  {|
I: Bus=0005 Vendor=054c Product=0ce6 Version=8100
N: Name="DualSense Wireless Controller"
P: Phys=00:11:22:33:44:55
S: Sysfs=/devices/virtual/misc/uhid/0005:054C:0CE6.0001/input/input42
U: Uniq=A0:FA:9C:6E:D7:F6
H: Handlers=event18 js0
B: PROP=0
B: EV=1b
B: KEY=7fff000000000000 0 0 0 0

I: Bus=0005 Vendor=054c Product=0ce6 Version=8100
N: Name="DualSense Wireless Controller Touchpad"
H: Handlers=event20 mouse2
B: EV=b
|}

let test_parse_proc_devices () =
  let entries = Proc_devices.parse fixture |> expect_ok in
  Alcotest.(check int) "entry count" 2 (List.length entries);
  let main = List.hd entries in
  Alcotest.(check (option string))
    "name" (Some "DualSense Wireless Controller") main.name;
  Alcotest.(check (list string)) "handlers" [ "event18"; "js0" ] main.handlers;
  Alcotest.(check (list string))
    "event handlers" [ "event18" ] (Proc_devices.event_handlers main);
  Alcotest.(check (list string))
    "event paths" [ "/dev/input/event18" ] (Proc_devices.event_paths main);
  Alcotest.(check bool) "vendor match" true (Proc_devices.matches_id ~vendor:0x054c main);
  Alcotest.(check bool)
    "product match" true (Proc_devices.matches_id ~vendor:0x054c ~product:0x0ce6 main);
  Alcotest.(check bool)
    "product mismatch" false (Proc_devices.matches_id ~vendor:0x054c ~product:0x1234 main)

let test_event_decode () =
  let ev =
    Event.of_raw ~sec:10L ~usec:20L ~event_type:Code.Ev.key
      ~code:Code.Key.btn_south ~value:1
  in
  Alcotest.(check int64) "sec" 10L ev.sec;
  Alcotest.(check int64) "usec" 20L ev.usec;
  Alcotest.(check string)
    "type" "key" (Event_type.to_string ev.event_type);
  Alcotest.(check int) "code" Code.Key.btn_south ev.code;
  Alcotest.(check int) "value" 1 ev.value

let test_event_type_roundtrip () =
  let values =
    [
      Event_type.Syn;
      Key;
      Rel;
      Abs;
      Msc;
      Sw;
      Led;
      Snd;
      Rep;
      Ff;
      Pwr;
      Ff_status;
      Unknown 999;
    ]
  in
  List.iter
    (fun value ->
      Alcotest.(check int)
        "roundtrip" (Event_type.to_int value)
        (Event_type.to_int (Event_type.of_int (Event_type.to_int value))))
    values

let () =
  Alcotest.run "eta_linux_input"
    [
      ( "proc devices",
        [ Alcotest.test_case "parse proc devices" `Quick test_parse_proc_devices ] );
      ( "events",
        [
          Alcotest.test_case "decode raw event" `Quick test_event_decode;
          Alcotest.test_case "event type roundtrip" `Quick test_event_type_roundtrip;
        ] );
    ]
