# Provider live reach probe

Question: do the shipped eta-ai provider packages reach real provider HTTPS
endpoints through eta-http, and does eta-http provide enough transport setup for
ordinary provider calls?

This is a release canary, not an offline CI test. It uses real provider keys
from the environment and sends a tiny chat request:

    Reply with exactly OK.

Run one provider:

    bash scratch/eta_ai_v1/probes/live_reach/run.sh openrouter

Run several providers:

    bash scratch/eta_ai_v1/probes/live_reach/run.sh anthropic mistral groq deepseek

Run every configured probe:

    bash scratch/eta_ai_v1/probes/live_reach/run.sh

Output is written to results/live_reach_latest.txt. The executable prints only
provider/model/status summaries and response lengths. It must not print API
keys or prompt/response content.

Current provider status is recorded in verdict.md.
