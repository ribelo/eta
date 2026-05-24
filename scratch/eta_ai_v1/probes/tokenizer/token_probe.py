import math

import tiktoken


SAMPLES = [
    (
        "english",
        "Summarize the invoice and extract the due date, total, and vendor name.",
    ),
    (
        "json_schema",
        '{"type":"object","properties":{"location":{"type":"string"},"unit":{"type":"string","enum":["celsius","fahrenheit"]}},"required":["location"],"additionalProperties":false}',
    ),
    (
        "code",
        "let rec fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)",
    ),
    (
        "cjk",
        "\u8bf7\u603b\u7ed3\u8fd9\u5f20\u53d1\u7968\u5e76\u63d0\u53d6\u5230\u671f\u65e5\u3001\u603b\u91d1\u989d\u548c\u4f9b\u5e94\u5546\u540d\u79f0\u3002",
    ),
    (
        "emoji",
        "Plan launch \U0001f680, rollback \U0001f501, and alerting \u2705 for the payment flow.",
    ),
    (
        "mixed_tool",
        'System: You are a support analyst. User: Find failed payments for customer usr_123 and explain next steps. Tool schema: {"customer_id":"usr_123","include_attempts":true}',
    ),
]


def rel_error(estimate: int, actual: int) -> float:
    return (estimate - actual) / actual


def pct(value: float) -> str:
    return f"{value * 100:.2f}%"


def main() -> None:
    enc = tiktoken.encoding_for_model("gpt-4o-mini")
    max_abs_byte4 = 0.0
    max_abs_wordish = 0.0

    print(
        "sample\ttokens\tbytes\tchars\tbyte4\tchar4\twordish\tbyte4_err\tchar4_err\twordish_err"
    )
    for name, text in SAMPLES:
        tokens = len(enc.encode(text))
        byte_len = len(text.encode("utf-8"))
        char_len = len(text)
        byte4 = math.ceil(byte_len / 4)
        char4 = math.ceil(char_len / 4)
        wordish = max(1, round(len(text.split()) * 1.33))
        byte4_err = rel_error(byte4, tokens)
        char4_err = rel_error(char4, tokens)
        wordish_err = rel_error(wordish, tokens)
        max_abs_byte4 = max(max_abs_byte4, abs(byte4_err))
        max_abs_wordish = max(max_abs_wordish, abs(wordish_err))
        print(
            f"{name}\t{tokens}\t{byte_len}\t{char_len}\t{byte4}\t{char4}\t{wordish}\t"
            f"{pct(byte4_err)}\t{pct(char4_err)}\t{pct(wordish_err)}"
        )

    print(f"max_abs_byte4_error={pct(max_abs_byte4)}")
    print(f"max_abs_wordish_error={pct(max_abs_wordish)}")
    if max_abs_byte4 >= 0.30:
        print("byte_count_estimate=failed")
    else:
        print("byte_count_estimate=accepted")
    print("selected_v1_shape=provider_usage_only")
    print("tokenizer_probe=ok")


if __name__ == "__main__":
    main()
