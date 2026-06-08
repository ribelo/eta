# 2026-05-24 live reach result

Environment key presence:

- OPENAI_API_KEY: present, but provider rejected it.
- ANTHROPIC_API_KEY: present.
- OPENROUTER_API_KEY: present.
- MISTRAL_API_KEY: present.
- GROQ_API_KEY: present.
- DEEPSEEK_API_KEY: present.
- KIMI_FOR_CODING_API_KEY: present.
- NOVITA_AI_API_KEY: present.
- ZAI_API_KEY: present.
- MOONSHOT_API_KEY: present.
- PERPLEXITY_API_KEY: present.
- TOGETHER_API_KEY: missing.
- FIREWORKS_API_KEY: missing.

Live canary outcomes:

| Provider | Package | Model | Outcome |
| --- | --- | --- | --- |
| OpenAI | eta-ai-openai | gpt-4o-mini | Reached provider; failed with status 401 invalid_api_key for configured key. |
| Anthropic | eta-ai-anthropic | claude-haiku-4-5-20251001 | Passed. |
| OpenRouter | eta-ai-openrouter | openai/gpt-4o-mini | Passed. |
| Mistral | eta-ai-openai-compat | mistral-small-latest | Passed. |
| Groq | eta-ai-openai-compat | llama-3.3-70b-versatile | Passed. |
| DeepSeek | eta-ai-openai-compat | deepseek-chat | Passed. |
| Kimi Code | eta-ai-openai-compat | kimi-for-coding | Reached provider; failed with status 403 because Kimi For Coding is restricted to supported coding agents. |
| Novita | eta-ai-openai-compat | deepseek/deepseek-v4-flash | Passed. |
| Z.ai | eta-ai-openai-compat | glm-4.5-air | Reached provider; failed with status 429 because the account has insufficient resources. |
| Moonshot | eta-ai-openai-compat | kimi-k2.6 | Reached provider; failed with status 429 because the account has insufficient balance. |
| Perplexity | eta-ai-openai-compat | sonar | Passed after raising the probe max_output_tokens to 16. |
| Together | eta-ai-openai-compat | meta-llama/Llama-3.3-70B-Instruct-Turbo | Skipped: missing key. |
| Fireworks | eta-ai-openai-compat | accounts/fireworks/models/llama-v3p1-8b-instruct | Skipped: missing key. |

Dogfooding finding:

The first live run failed every HTTPS provider before provider payloads reached
the wire because ocaml-tls needs Mirage_crypto_rng initialized. The fix moved
that setup into eta-http's TLS transport path.

Verification after the eta-http fix:

    nix develop -c dune exec ./scratch/eta_ai_v1/probes/live_reach/live_reach.exe -- anthropic
    exit 0
    ok provider=anthropic model=claude-haiku-4-5-20251001 output_len=2 finish_reasons=1

    nix develop -c eta-oxcaml-test-shipped
    exit 0

Sanitization recheck:

    nix develop -c dune build ./scratch/eta_ai_v1/probes/live_reach/live_reach.exe
    exit 0

    nix develop -c bash scratch/eta_ai_v1/probes/live_reach/run.sh openai
    exit 1
    fail provider=openai model=gpt-4o-mini provider=openai status=401 code=invalid_api_key message=Incorrect API key provided: <redacted:api_key> You can find your API key at https://platform.openai.com/account/api-keys.

This keeps unavailable paid/product-scope live successes as reopeners while
ensuring the reusable canary does not write provider-returned key fragments to
its latest-result file.

Expanded AP3 recheck:

    nix develop -c bash scratch/eta_ai_v1/probes/live_reach/run.sh deepseek groq kimi-code novita zai moonshot perplexity
    exit 1
    ok provider=groq model=llama-3.3-70b-versatile output_len=2 finish_reasons=1
    ok provider=deepseek model=deepseek-chat output_len=3 finish_reasons=1
    fail provider=kimi-code model=kimi-for-coding provider=kimi-code status=403 code=none message=Kimi For Coding is currently only available for Coding Agents such as Kimi CLI, Claude Code, Roo Code, Kilo Code, etc.
    ok provider=novita model=deepseek/deepseek-v4-flash output_len=3 finish_reasons=1
    fail provider=zai model=glm-4.5-air provider=zai status=429 code=1113 message=insufficient resources
    fail provider=moonshot model=kimi-k2.6 provider=moonshot status=429 code=none message=Your account <redacted:account> <redacted:api_key> is suspended due to insufficient balance, please recharge your account or check your plan and billing details
    ok provider=perplexity model=sonar output_len=2 finish_reasons=1

Secret scan after the expanded recheck found no exact configured env-key values
and no sk-/ak-/org- token patterns in results/live_reach_latest.txt.
