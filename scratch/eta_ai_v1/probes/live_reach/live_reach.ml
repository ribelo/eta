module A = Ai
module E = Eta.Effect
module H = Http

type probe = {
  name : string;
  env : string;
  model : string;
  run : H.Client.t -> api_key:A.api_key -> A.chat_request -> (A.response, A.ai_error) E.t;
}

let request model =
  {
    A.model;
    prompt = [ A.User [ A.Text "Reply with exactly OK." ] ];
    tools = [];
    temperature = Some 0.0;
    max_output_tokens = Some 4;
    stream = false;
  }

let assistant_text = function
  | A.Assistant { content; _ } ->
      content
      |> List.filter_map (function A.Text text -> Some text | A.Json _ -> None)
      |> String.concat ""
  | _ -> ""

let contains text needle =
  let text_len = String.length text in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > text_len then false
  else
    let rec loop index =
      if index + needle_len > text_len then false
      else if String.equal (String.sub text index needle_len) needle then true
      else loop (index + 1)
    in
    loop 0

let replace_all ~needle ~replacement text =
  let needle_len = String.length needle in
  if needle_len = 0 then text
  else
    let text_len = String.length text in
    let buffer = Buffer.create text_len in
    let rec loop index =
      if index >= text_len then ()
      else if
        index + needle_len <= text_len
        && String.equal (String.sub text index needle_len) needle
      then (
        Buffer.add_string buffer replacement;
        loop (index + needle_len))
      else (
        Buffer.add_char buffer text.[index];
        loop (index + 1))
    in
    loop 0;
    Buffer.contents buffer

let key_env_names =
  [
    "OPENAI_API_KEY";
    "ANTHROPIC_API_KEY";
    "OPENROUTER_API_KEY";
    "MISTRAL_API_KEY";
    "GROQ_API_KEY";
    "DEEPSEEK_API_KEY";
    "KIMI_FOR_CODING_API_KEY";
    "NOVITA_AI_API_KEY";
    "ZAI_API_KEY";
    "MOONSHOT_API_KEY";
    "PERPLEXITY_API_KEY";
    "TOGETHER_API_KEY";
    "FIREWORKS_API_KEY";
  ]

let redact_known_env_values text =
  List.fold_left
    (fun text env_name ->
      match Sys.getenv_opt env_name with
      | Some value when String.length value >= 8 ->
          replace_all ~needle:value ~replacement:"<redacted:api_key>" text
      | _ -> text)
    text key_env_names

let redact_sensitive_text text =
  text |> redact_known_env_values |> String.split_on_char ' '
  |> List.map (fun token ->
         let lower = String.lowercase_ascii token in
         if contains lower "sk-" || contains lower "ak-" then
           "<redacted:api_key>"
         else if contains lower "org-" then "<redacted:account>"
         else token)
  |> String.concat " "

let request_for_probe probe =
  let request = request probe.model in
  if String.equal probe.name "perplexity" then
    { request with A.max_output_tokens = Some 16 }
  else request

let error_summary = function
  | A.Http_error error -> "http " ^ redact_sensitive_text (H.Error.to_string error)
  | A.Provider_error { provider; status; code; message; _ } ->
      Printf.sprintf "provider=%s status=%s code=%s message=%s" provider
        (match status with Some status -> string_of_int status | None -> "none")
        (Option.value ~default:"none" code)
        (redact_sensitive_text message)
  | A.Decode_error { provider; message; _ } ->
      Printf.sprintf "decode provider=%s message=%s" provider
        (redact_sensitive_text message)
  | A.Invalid_tool { name; message } ->
      Printf.sprintf "invalid_tool name=%s message=%s" name
        (redact_sensitive_text message)
  | A.Unsupported { provider; feature } ->
      Printf.sprintf "unsupported provider=%s feature=%s" provider feature

let rec cause_summary = function
  | Eta.Cause.Fail error -> error_summary error
  | Die { exn; _ } -> "die " ^ Printexc.to_string exn
  | Interrupt _ -> "interrupt"
  | Sequential causes ->
      "sequential [" ^ String.concat "; " (List.map cause_summary causes) ^ "]"
  | Concurrent causes ->
      "concurrent [" ^ String.concat "; " (List.map cause_summary causes) ^ "]"
  | Suppressed { primary; finalizer } ->
      "suppressed primary=[" ^ cause_summary primary ^ "] finalizer=["
      ^ cause_summary finalizer ^ "]"

let run_probe rt client probe =
  match Sys.getenv_opt probe.env with
  | None ->
      Printf.printf "skip provider=%s env=%s reason=missing_key\n%!" probe.name
        probe.env;
      true
  | Some key when String.equal key "" ->
      Printf.printf "skip provider=%s env=%s reason=empty_key\n%!" probe.name
        probe.env;
      true
  | Some key -> (
      let request = request_for_probe probe in
      match
        Eta.Runtime.run rt
          (probe.run client ~api_key:(A.api_key key) request)
      with
      | Eta.Exit.Ok response ->
          let text = assistant_text response.message in
          Printf.printf
            "ok provider=%s model=%s output_len=%d finish_reasons=%d\n%!"
            probe.name probe.model (String.length text)
            (List.length response.finish_reasons);
          true
      | Eta.Exit.Error cause ->
          Printf.printf "fail provider=%s model=%s %s\n%!" probe.name
            probe.model (cause_summary cause);
          false)

let compat_provider ~name ~base_url () =
  Ai_openai_compat.provider ~name ~base_url ()

let probes =
  [
    {
      name = "openai";
      env = "OPENAI_API_KEY";
      model = "gpt-4o-mini";
      run =
        (fun client ~api_key request ->
          Ai_openai.chat_completions client ~api_key request);
    };
    {
      name = "anthropic";
      env = "ANTHROPIC_API_KEY";
      model = "claude-haiku-4-5-20251001";
      run =
        (fun client ~api_key request ->
          Ai_anthropic.messages client ~api_key request);
    };
    {
      name = "openrouter";
      env = "OPENROUTER_API_KEY";
      model = "openai/gpt-4o-mini";
      run =
        (fun client ~api_key request ->
          Ai_openrouter.responses client ~api_key request);
    };
    {
      name = "mistral";
      env = "MISTRAL_API_KEY";
      model = "mistral-small-latest";
      run =
        (fun client ~api_key request ->
          let provider =
            compat_provider ~name:"mistral" ~base_url:"https://api.mistral.ai"
              ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "groq";
      env = "GROQ_API_KEY";
      model = "llama-3.3-70b-versatile";
      run =
        (fun client ~api_key request ->
          let provider =
            compat_provider ~name:"groq"
              ~base_url:"https://api.groq.com/openai" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "deepseek";
      env = "DEEPSEEK_API_KEY";
      model = "deepseek-chat";
      run =
        (fun client ~api_key request ->
          let provider =
            compat_provider ~name:"deepseek" ~base_url:"https://api.deepseek.com"
              ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "kimi-code";
      env = "KIMI_FOR_CODING_API_KEY";
      model = "kimi-for-coding";
      run =
        (fun client ~api_key request ->
          let provider =
            Ai_openai_compat.provider ~name:"kimi-code"
              ~base_url:"https://api.kimi.com/coding/v1"
              ~chat_path:"/chat/completions" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "novita";
      env = "NOVITA_AI_API_KEY";
      model = "deepseek/deepseek-v4-flash";
      run =
        (fun client ~api_key request ->
          let provider =
            Ai_openai_compat.provider ~name:"novita"
              ~base_url:"https://api.novita.ai/v3/openai"
              ~chat_path:"/chat/completions" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "zai";
      env = "ZAI_API_KEY";
      model = "glm-4.5-air";
      run =
        (fun client ~api_key request ->
          let provider =
            Ai_openai_compat.provider ~name:"zai"
              ~base_url:"https://open.bigmodel.cn/api/paas/v4"
              ~chat_path:"/chat/completions" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "moonshot";
      env = "MOONSHOT_API_KEY";
      model = "kimi-k2.6";
      run =
        (fun client ~api_key request ->
          let provider =
            Ai_openai_compat.provider ~name:"moonshot"
              ~base_url:"https://api.moonshot.ai/v1"
              ~chat_path:"/chat/completions" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "perplexity";
      env = "PERPLEXITY_API_KEY";
      model = "sonar";
      run =
        (fun client ~api_key request ->
          let provider =
            Ai_openai_compat.provider ~name:"perplexity"
              ~base_url:"https://api.perplexity.ai"
              ~chat_path:"/chat/completions" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "together";
      env = "TOGETHER_API_KEY";
      model = "meta-llama/Llama-3.3-70B-Instruct-Turbo";
      run =
        (fun client ~api_key request ->
          let provider =
            compat_provider ~name:"together"
              ~base_url:"https://api.together.xyz" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
    {
      name = "fireworks";
      env = "FIREWORKS_API_KEY";
      model = "accounts/fireworks/models/llama-v3p1-8b-instruct";
      run =
        (fun client ~api_key request ->
          let provider =
            compat_provider ~name:"fireworks"
              ~base_url:"https://api.fireworks.ai/inference" ()
          in
          Ai_openai_compat.chat_completions ~provider client ~api_key request);
    };
  ]

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let client = H.Client.make ~sw ~net:(Eio.Stdenv.net stdenv) () in
  let selected =
    Sys.argv |> Array.to_list |> List.tl
    |> List.filter (fun value -> not (String.equal value ""))
  in
  let probes =
    match selected with
    | [] -> probes
    | names ->
        List.filter (fun probe -> List.mem probe.name names) probes
  in
  let results = List.map (run_probe rt client) probes in
  let shutdown_ok =
    let shutdown =
      H.Client.shutdown client |> E.catch (fun error -> E.fail (A.Http_error error))
    in
    match Eta.Runtime.run rt shutdown with
    | Eta.Exit.Ok () -> true
    | Eta.Exit.Error cause ->
        Printf.printf "fail provider=eta-http-shutdown %s\n%!"
          (cause_summary cause);
        false
  in
  if not (shutdown_ok && List.for_all Fun.id results) then exit 1
