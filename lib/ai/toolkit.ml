open Types

module Tool_name_set = Set.Make (String)

type t = { rev_tools : tool list; names : Tool_name_set.t }

let invalid_tool name message = Stdlib.Error (Invalid_tool { name; message })
let normalize_tool_name = String.trim

let validate_tool (tool : tool) =
  let name = normalize_tool_name tool.name in
  if String.equal name "" then invalid_tool tool.name "tool name is required"
  else if String.equal (String.trim tool.input_schema_json) "" then
    invalid_tool tool.name "input_schema_json is required"
  else Stdlib.Ok { tool with name }

let make_tool ?description ?strict ~name ~input_schema_json () =
  validate_tool { name; description; input_schema_json; strict }

let empty_toolkit = { rev_tools = []; names = Tool_name_set.empty }

let toolkit_tools toolkit = List.rev toolkit.rev_tools

let find_tool name (toolkit : t) =
  let name = normalize_tool_name name in
  List.find_opt
    (fun (tool : tool) -> String.equal tool.name name)
    toolkit.rev_tools

let add_tool (tool : tool) (toolkit : t) =
  match validate_tool tool with
  | Stdlib.Error _ as error -> error
  | Stdlib.Ok tool ->
      if Tool_name_set.mem tool.name toolkit.names then
        invalid_tool tool.name "tool name already registered"
      else
        Stdlib.Ok
          {
            rev_tools = tool :: toolkit.rev_tools;
            names = Tool_name_set.add tool.name toolkit.names;
          }

let make_toolkit tools =
  let rec loop acc = function
    | [] -> Stdlib.Ok acc
    | tool :: rest -> (
        match add_tool tool acc with
        | Stdlib.Ok acc -> loop acc rest
        | Stdlib.Error _ as error -> error)
  in
  loop empty_toolkit tools
