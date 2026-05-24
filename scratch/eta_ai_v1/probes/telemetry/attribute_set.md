# A5 telemetry attribute set

Source:

- OpenTelemetry semantic-conventions-genai repository.
- Files checked:
  - model/gen-ai/spans.yaml
  - model/gen-ai/registry.yaml
- Status in source: development.

eta-ai v1 span names:

| Operation | Span kind | Span name |
| --- | --- | --- |
| chat | Client | chat {model} |
| streaming chat | Client | chat {model} |
| embeddings | Client | embeddings {model} |
| tool execution | Internal | execute_tool {tool_name} |

Required/common attributes:

| Attribute | Use |
| --- | --- |
| gen_ai.operation.name | chat, embeddings, execute_tool |
| gen_ai.provider.name | provider slug such as openai or anthropic |
| gen_ai.request.model | requested model |
| server.address | provider host |
| server.port | provider port |
| error.type | low-cardinality provider/client error class when failed |

Recommended response/usage attributes when available:

| Attribute | Use |
| --- | --- |
| gen_ai.response.id | provider response id |
| gen_ai.response.model | actual response model |
| gen_ai.response.finish_reasons | stop/tool/error reasons |
| gen_ai.usage.input_tokens | provider input usage |
| gen_ai.usage.output_tokens | provider output usage |
| gen_ai.request.stream | true only for streaming requests |
| gen_ai.response.time_to_first_chunk | streaming time-to-first-chunk in seconds |
| gen_ai.request.encoding_formats | embeddings format when supplied |

Tool attributes:

| Attribute | Use |
| --- | --- |
| gen_ai.tool.definitions | opt-in, names or redacted definitions available to model |
| gen_ai.tool.name | executed tool name |
| gen_ai.tool.call.id | provider tool-call id |
| gen_ai.tool.type | function, extension, datastore, or provider-specific kind |

Content attributes are opt-in only:

- gen_ai.system_instructions
- gen_ai.input.messages
- gen_ai.output.messages
- gen_ai.tool.call.arguments
- gen_ai.tool.call.result

Default eta-ai v1 behavior should not record prompt, output, tool arguments, or
tool results unless the caller explicitly opts in.
