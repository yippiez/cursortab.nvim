#!/usr/bin/env python3
"""Minimal offline eval harness for cursortab local completion.

Loads an eval folder (eval.json + repo/), assembles a completion prompt under
one or more context conditions, sends it to a running llama-server, and checks
the completion against the eval's expectations.

Usage:
  python3 evals/run.py evals/python-function-in-bash --provider fim
  python3 evals/run.py --all --provider sweep --url http://localhost:8000
"""
import argparse, json, os, urllib.request

# ---- FIM (Qwen2.5-Coder) ----
FIM = dict(prefix="<|fim_prefix|>", suffix="<|fim_suffix|>", middle="<|fim_middle|>",
           repo="<|repo_name|>", sep="<|file_sep|>")


def build_fim(target_path, prefix, suffix, context):
    p = ""
    if context:
        p += FIM["repo"] + "repo\n"
        for path, body in context:
            p += FIM["sep"] + path + "\n" + body + "\n"
        p += FIM["sep"] + target_path + "\n"
    p += FIM["prefix"] + prefix + FIM["suffix"] + suffix + FIM["middle"]
    return p, ["<|endoftext|>", FIM["sep"]]


# ---- Sweep next-edit ----
def build_sweep(target_path, lines, cur_row, cur_col, context):
    initial = "\n".join(lines)
    cb = "\n".join(lines)
    n = len(lines)
    off = sum(len(lines[i]) + 1 for i in range(cur_row)) + cur_col
    off = min(off, len(cb))
    cbc = cb[:off] + "<|cursor|>" + cb[off:]
    pre = cb[:off]
    prefill = cb[:pre.rfind("\n") + 1] if "\n" in pre else ""
    p = f"<|file_sep|>{target_path}\n{initial}\n"
    if context:
        p += "<|file_sep|>context/retrieval\n"
        for path, body in context:
            p += f"<|file_sep|>{path}\n{body}\n"
    p += f"<|file_sep|>original/{target_path}:1:{n}\n{cb}\n"
    p += f"<|file_sep|>current/{target_path}:1:{n}\n{cbc}\n"
    p += f"<|file_sep|>updated/{target_path}:1:{n}\n{prefill}"
    return p, ["<|file_sep|>", "<|endoftext|>"]


def complete(url, prompt, stop, max_tokens=160):
    body = json.dumps({"prompt": prompt, "temperature": 0, "max_tokens": max_tokens,
                       "stop": stop, "top_k": 50, "n": 1}).encode()
    req = urllib.request.Request(url.rstrip("/") + "/v1/completions", body,
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=60))["choices"][0]["text"]


def check(text, expect):
    fails = []
    for s in expect.get("must_contain", []):
        if s not in text:
            fails.append(f"missing required: {s!r}")
    for s in expect.get("must_not_contain", []):
        if s in text:
            fails.append(f"contains forbidden: {s!r}")
    soft = [s for s in expect.get("should_contain", []) if s not in text]
    return (not fails), fails, soft


def load_eval(d):
    spec = json.load(open(os.path.join(d, "eval.json")))
    target_rel = spec["target"]
    text = open(os.path.join(d, target_rel)).read()
    lines = text.split("\n")
    cur_row, cur_col = len(lines) - 1, len(lines[-1])  # cursor == eof for now
    ctx = [(cf, open(os.path.join(d, cf)).read()) for cf in spec.get("context_files", [])]
    return spec, target_rel, text, lines, cur_row, cur_col, ctx


def run_one(d, provider, url):
    spec, tpath, text, lines, r, c, ctx = load_eval(d)
    print(f"\n=== {spec['name']}  (provider={provider}) ===")
    any_fail = False
    for cond, use_ctx in [("baseline", False), ("files-around", True)]:
        context = ctx if use_ctx else []
        if provider == "fim":
            prompt, stop = build_fim(tpath, text, "", context)
        else:
            prompt, stop = build_sweep(tpath, lines, r, c, context)
        out = complete(url, prompt, stop)
        ok, fails, soft = check(out, spec["expect"])
        any_fail = any_fail or not ok
        print(f"\n[{cond}] {'PASS' if ok else 'FAIL'}" + (f"  (soft-miss: {soft})" if soft else ""))
        for f in fails:
            print("   - " + f)
        print("   output> " + out.strip().replace("\n", "\n            "))
    return not any_fail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("eval_dir", nargs="?")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--provider", choices=["fim", "sweep"], default="fim")
    ap.add_argument("--url", default="http://localhost:8000")
    a = ap.parse_args()
    root = os.path.dirname(os.path.abspath(__file__))
    if a.all:
        dirs = [os.path.join(root, x) for x in sorted(os.listdir(root))
                if os.path.isfile(os.path.join(root, x, "eval.json"))]
    elif a.eval_dir:
        dirs = [a.eval_dir]
    else:
        ap.error("give an eval dir or --all")
    ok = all(run_one(d, a.provider, a.url) for d in dirs)
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
