open Eta_http_testsuite

type case = {
  name : string;
  transport : Types.transport;
  port : int;
  command : string list;
  stdout_path : string;
  stderr_path : string;
  junit_path : string;
  server_stdout_path : string;
  server_stderr_path : string;
  exit_code : int;
  success : bool;
  duration_ms : float;
}

let fail msg =
  prerr_endline msg;
  exit 1

let expect_ok = function
  | Ok value -> value
  | Error error -> fail error

let transport_slug = function
  | Types.Plain -> "h2c"
  | TLS -> "h2-tls"

let transport_of_slug = function
  | "h2c" -> Types.Plain
  | "h2-tls" -> TLS
  | other -> fail ("unknown h2spec server transport: " ^ other)

let conformance_config =
  let body_limit = 16 * 1024 * 1024 in
  let server =
    {
      Eta_http.Server.Config.default with
      unread_body_policy = Drain_up_to body_limit;
      limits =
        {
          Eta_http.Server.Config.default.limits with
          max_request_body_bytes = Some body_limit;
        };
    }
  in
  { Eta_http_eio.Server.Config.default with server }

let handler request =
  Eta_http.Server.Body.read_all request.Eta_http.Server.Request.body
  |> Eta.Effect.map (fun _body -> Eta_server.text "eta-h2spec\n")
  |> Eta.Effect.catch (fun _error -> Eta.Effect.pure (Eta_server.empty 500))

let tls_config cert_dir =
  Eta_http.Tls.Config.default_server
    ~certificate_chain_file:(Certs.cert_path cert_dir)
    ~private_key_file:(Certs.key_path cert_dir)
    ~alpn_protocols:[ "h2" ] ()

let serve transport port cert_dir =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
  match transport with
  | Types.Plain ->
      Eta_http_eio.Server.run_h2c ~sw ~net ~clock
        ~config:conformance_config ~addr handler
  | TLS ->
      Eta_http_eio.Server.run_https ~sw ~net ~clock
        ~config:conformance_config ~tls_config:(tls_config cert_dir) ~addr
        handler

let close_noerr fd =
  try Unix.close fd with
  | Unix.Unix_error (Unix.EBADF, _, _) -> ()
  | _ -> ()

let open_log path =
  Unix.openfile path
    [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ]
    0o644

let spawn_server ~results_dir ~transport ~port ~cert_dir =
  let name = transport_slug transport in
  let stdout_path = Filename.concat results_dir (name ^ ".server.stdout.txt") in
  let stderr_path = Filename.concat results_dir (name ^ ".server.stderr.txt") in
  let stdout_fd = open_log stdout_path in
  let stderr_fd = open_log stderr_path in
  let argv =
    [|
      Sys.executable_name;
      "serve";
      name;
      string_of_int port;
      cert_dir;
    |]
  in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        close_noerr stdout_fd;
        close_noerr stderr_fd)
      (fun () ->
        Unix.create_process Sys.executable_name argv Unix.stdin stdout_fd
          stderr_fd)
  in
  (pid, stdout_path, stderr_path)

let rec waitpid_nonblocking pid attempts =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ when attempts > 0 ->
      Unix.sleepf 0.05;
      waitpid_nonblocking pid (attempts - 1)
  | 0, _ ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      ignore (Unix.waitpid [] pid)
  | _, _ -> ()
  | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ()

let stop_server pid =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  waitpid_nonblocking pid 100

let try_connect port =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> close_noerr fd)
    (fun () ->
      Unix.connect fd
        (Unix.ADDR_INET (Unix.inet_addr_loopback, port)))

let rec wait_for_tcp ~port attempts =
  if attempts = 0 then fail (Printf.sprintf "server did not listen on %d" port);
  match try_connect port with
  | () -> ()
  | exception _ ->
      Unix.sleepf 0.05;
      wait_for_tcp ~port (attempts - 1)

let shell_command ~stdout_path ~stderr_path command =
  String.concat " " (List.map Filename.quote command)
  ^ " > " ^ Filename.quote stdout_path
  ^ " 2> " ^ Filename.quote stderr_path

let h2spec_command ~port ~transport ~junit_path =
  let base =
    [
      "timeout";
      "900s";
      "h2spec";
      "--strict";
      "--timeout";
      "5";
      "--host";
      "127.0.0.1";
      "--port";
      string_of_int port;
      "--path";
      "/";
      "--junit-report";
      junit_path;
    ]
  in
  match transport with
  | Types.Plain -> base
  | TLS -> base @ [ "--tls"; "--insecure" ]

let run_process ~results_dir ~name command =
  let stdout_path = Filename.concat results_dir (name ^ ".stdout.txt") in
  let stderr_path = Filename.concat results_dir (name ^ ".stderr.txt") in
  let start = Util.now_ms () in
  let exit_code = Sys.command (shell_command ~stdout_path ~stderr_path command) in
  (stdout_path, stderr_path, exit_code, Util.now_ms () -. start)

let run_case ~results_dir ~cert_dir transport =
  let port = Util.random_port () in
  let name = transport_slug transport in
  let pid, server_stdout_path, server_stderr_path =
    spawn_server ~results_dir ~transport ~port ~cert_dir
  in
  Fun.protect
    ~finally:(fun () -> stop_server pid)
    (fun () ->
      wait_for_tcp ~port 100;
      let junit_path = Filename.concat results_dir (name ^ ".junit.xml") in
      let command = h2spec_command ~port ~transport ~junit_path in
      Printf.printf "h2spec %s port=%d\n%!" name port;
      let stdout_path, stderr_path, exit_code, duration_ms =
        run_process ~results_dir ~name command
      in
      {
        name;
        transport;
        port;
        command;
        stdout_path;
        stderr_path;
        junit_path;
        server_stdout_path;
        server_stderr_path;
        exit_code;
        success = exit_code = 0;
        duration_ms;
      })

let json_of_case case =
  `Assoc
    [
      ("name", `String case.name);
      ("transport", Json.yojson_of_transport case.transport);
      ("port", `Int case.port);
      ("command", `List (List.map (fun value -> `String value) case.command));
      ("stdout_path", `String case.stdout_path);
      ("stderr_path", `String case.stderr_path);
      ("junit_path", `String case.junit_path);
      ("server_stdout_path", `String case.server_stdout_path);
      ("server_stderr_path", `String case.server_stderr_path);
      ("exit_code", `Int case.exit_code);
      ("success", `Bool case.success);
      ("duration_ms", `Float case.duration_ms);
    ]

let render_command command =
  String.concat " " (List.map Filename.quote command)

let first_lines path limit =
  if not (Sys.file_exists path) then []
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop acc remaining =
          if remaining = 0 then List.rev acc
          else
            match input_line ic with
            | line -> loop (line :: acc) (remaining - 1)
            | exception End_of_file -> List.rev acc
        in
        loop [] limit)

let render_report ~path cases =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      Printf.fprintf oc "# Eta HTTP/2 h2spec Conformance\n\n";
      Printf.fprintf oc "- Tool: h2spec %s\n"
        (Util.version_of_cmd "h2spec --version");
      Printf.fprintf oc "- Strict mode: enabled\n";
      Printf.fprintf oc "- Generated: %s\n\n" (Util.utc_timestamp ());
      List.iter
        (fun case ->
          Printf.fprintf oc "## %s\n\n" case.name;
          Printf.fprintf oc "- Transport: %s\n" case.name;
          Printf.fprintf oc "- Port: %d\n" case.port;
          Printf.fprintf oc "- Exit code: %d\n" case.exit_code;
          Printf.fprintf oc "- Success: %b\n" case.success;
          Printf.fprintf oc "- Duration: %.0f ms\n" case.duration_ms;
          Printf.fprintf oc "- Command: `%s`\n" (render_command case.command);
          Printf.fprintf oc "- Stdout: `%s`\n" case.stdout_path;
          Printf.fprintf oc "- Stderr: `%s`\n" case.stderr_path;
          Printf.fprintf oc "- JUnit: `%s`\n" case.junit_path;
          Printf.fprintf oc "- Server stdout: `%s`\n" case.server_stdout_path;
          Printf.fprintf oc "- Server stderr: `%s`\n\n"
            case.server_stderr_path;
          let preview = first_lines case.stdout_path 40 in
          if preview <> [] then (
            Printf.fprintf oc "```text\n";
            List.iter (Printf.fprintf oc "%s\n") preview;
            Printf.fprintf oc "```\n\n"))
        cases)

let repo_root () =
  match Util.run_cmd_out "git rev-parse --show-toplevel" with
  | Ok (root :: _) -> String.trim root
  | Ok [] | Error _ -> Sys.getcwd ()

let run_parent () =
  let results_root =
    if Array.length Sys.argv > 1 then Sys.argv.(1)
    else Filename.concat (repo_root ()) "http-testsuite/results"
  in
  let run_id =
    Printf.sprintf "%s-%s" (Util.utc_timestamp ()) (Util.git_sha ())
  in
  let results_dir = Filename.concat results_root run_id in
  Util.mkdir_p results_dir;
  let temp_dir = Filename.concat results_dir "h2spec-fixtures" in
  Util.mkdir_p temp_dir;
  ignore (Fixtures.generate ~dir:temp_dir);
  let cert_dir = Certs.prepare ~temp_dir |> expect_ok in
  Printf.printf "h2spec_runner run_id=%s results_dir=%s\n%!" run_id
    results_dir;
  let h2c = run_case ~results_dir ~cert_dir Types.Plain in
  let h2_tls = run_case ~results_dir ~cert_dir TLS in
  let cases = [ h2c; h2_tls ] in
  Json.write_json
    ~path:(Filename.concat results_dir "h2spec.json")
    (`List (List.map json_of_case cases));
  render_report ~path:(Filename.concat results_dir "h2spec.md") cases;
  Printf.printf "h2spec_runner done results_dir=%s\n%!" results_dir;
  if List.exists (fun case -> not case.success) cases then exit 1

let () =
  match Array.to_list Sys.argv with
  | _ :: "serve" :: transport :: port :: cert_dir :: _ ->
      serve (transport_of_slug transport) (int_of_string port) cert_dir
  | _ -> run_parent ()
