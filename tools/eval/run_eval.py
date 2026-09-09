#!/usr/bin/env python3
"""Run the P0.5 baseline eval over tools/eval's zh/en mixed-typing corpus.

This measures the *current* (pre-F1) engine's behavior, not a target: it
exists so future F1/F2 work has a number to beat, per the "Software 2.0"
principle of measuring before building.

Two independent metrics, both driven by the compiled mixime-eval CLI so the
numbers reflect the real engine, not a re-implementation of it:

  F1 (English-segment retention): for each corpus row, type its `keys`
  column (mode "keys" -- the full, realistic simulation of typing English
  and Chinese back-to-back through the stock Bopomofo key handler) and
  check whether each gold English token still appears literally in the
  composed output. The current engine has no English-detection logic at
  all, so this is expected to be at or near 0%; see BASELINE.md.

  F2 (homophone/candidate-selection accuracy): for each row, concatenate
  the gold Bopomofo readings for its zh segments only (mode "readings" --
  bypasses key handling and English entirely) and compare the composed
  text against the gold zh text, character by character. This isolates
  the language model's candidate ranking from the English-interference
  problem that F1 measures.

Usage:
  python3 tools/eval/run_eval.py --corpus <path-to-eval200.tsv> \\
      --cli ./build-engine/tools/eval/mixime-eval --data <ResourcesDir>
"""

from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import subprocess
import sys
from pathlib import Path


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run_cli_batch(cli: Path, data_dir: Path, mode: str, lines: list[str]) -> list[list[str]]:
    if not lines:
        return []
    proc = subprocess.run(
        [str(cli), "--data", str(data_dir), "--mode", mode],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
        check=True,
    )
    out_lines = proc.stdout.rstrip("\n").split("\n")
    if len(out_lines) != len(lines):
        raise RuntimeError(
            f"mode {mode}: got {len(out_lines)} output lines for {len(lines)} "
            f"input lines (stderr: {proc.stderr.strip()[:1000]})"
        )
    return [line.split("\t") for line in out_lines]


def load_corpus(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 6:
                raise ValueError(f"{path}:{lineno}: expected 6 TSV columns, got {len(parts)}")
            row_id, sentence, segments_json, readings, keys, source = parts
            rows.append(
                {
                    "id": row_id,
                    "sentence": sentence,
                    "segments": json.loads(segments_json),
                    "readings": readings,
                    "keys": keys,
                    "source": source,
                }
            )
    return rows


def percentile(values: list[int], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return float(s[f])
    return s[f] + (s[c] - s[f]) * (k - f)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--baseline-out", type=Path, default=Path(__file__).resolve().parent / "BASELINE.md")
    args = parser.parse_args()

    rows = load_corpus(args.corpus)
    if not rows:
        print("error: corpus is empty", file=sys.stderr)
        return 1

    # ---- F1: type the full `keys` column through mode "keys" ----
    keys_out = run_cli_batch(args.cli, args.data, "keys", [r["keys"] for r in rows])

    f1_total_tokens = 0
    f1_retained_tokens = 0
    f1_latencies_us = []
    f1_row_all_retained = 0
    for row, out in zip(rows, keys_out):
        composed, _uncomposable, latency_us = out[0], out[1], int(out[2])
        f1_latencies_us.append(latency_us)
        en_tokens = [seg["text"] for seg in row["segments"] if seg["lang"] == "en"]
        composed_lower = composed.lower()
        row_all_ok = True
        for tok in en_tokens:
            f1_total_tokens += 1
            if tok.lower() in composed_lower:
                f1_retained_tokens += 1
            else:
                row_all_ok = False
        if en_tokens and row_all_ok:
            f1_row_all_retained += 1

    f1_rate = (f1_retained_tokens / f1_total_tokens * 100) if f1_total_tokens else 0.0
    f1_row_rate = (f1_row_all_retained / len(rows) * 100) if rows else 0.0

    # ---- F2: concatenate zh-segment readings through mode "readings" ----
    f2_reading_lines = []
    f2_gold_texts = []
    for row in rows:
        f2_reading_lines.append(row["readings"].replace("|", " "))
        f2_gold_texts.append("".join(seg["text"] for seg in row["segments"] if seg["lang"] == "zh"))

    readings_out = run_cli_batch(args.cli, args.data, "readings", f2_reading_lines)

    f2_total_chars = 0
    f2_correct_chars = 0
    f2_latencies_us = []
    f2_length_mismatches = 0
    for gold, out in zip(f2_gold_texts, readings_out):
        composed, _insert_failures, latency_us = out[0], out[1], int(out[2])
        f2_latencies_us.append(latency_us)
        if len(composed) != len(gold):
            f2_length_mismatches += 1
            # Still score the overlapping prefix so one bad row doesn't zero
            # out the whole comparison.
        for i in range(min(len(gold), len(composed))):
            f2_total_chars += 1
            if gold[i] == composed[i]:
                f2_correct_chars += 1
        f2_total_chars += max(0, len(gold) - len(composed))  # missing chars count as wrong

    f2_rate = (f2_correct_chars / f2_total_chars * 100) if f2_total_chars else 0.0

    vault_n = sum(1 for r in rows if r["source"] == "vault")
    synthetic_n = sum(1 for r in rows if r["source"] == "synthetic")

    def stats_line(label: str, values: list[int]) -> str:
        if not values:
            return f"{label}: n/a"
        return (
            f"{label}: avg={statistics.mean(values):.0f}us "
            f"p50={percentile(values, 0.5):.0f}us "
            f"p95={percentile(values, 0.95):.0f}us "
            f"max={max(values)}us"
        )

    report_lines = [
        f"Corpus: {args.corpus} ({len(rows)} rows: vault={vault_n}, synthetic={synthetic_n})",
        "",
        f"F1 (English segment retention, mode=keys):",
        f"  token-level : {f1_retained_tokens}/{f1_total_tokens} = {f1_rate:.1f}%",
        f"  row-level   : {f1_row_all_retained}/{len(rows)} rows fully retained = {f1_row_rate:.1f}%",
        f"  {stats_line('  latency', f1_latencies_us)}",
        "",
        f"F2 (homophone/candidate-selection accuracy, mode=readings):",
        f"  char-level  : {f2_correct_chars}/{f2_total_chars} = {f2_rate:.1f}%",
        f"  length mismatches (composed != gold length): {f2_length_mismatches}/{len(rows)} rows",
        f"  {stats_line('  latency', f2_latencies_us)}",
    ]
    report = "\n".join(report_lines)
    print(report)

    import datetime

    baseline_md = f"""# mixime P0.5 baseline

Generated: {datetime.datetime.now().astimezone().isoformat(timespec='seconds')}

Engine: mixime (fork of McBopomofo, upstream commit f5ba010 at fork time),
unmodified F1/F2 logic -- this is the *baseline*, i.e. what the stock
McBopomofo engine does today, before any zh/en mixed-typing or AI
re-ranking work lands.

Corpus: `{args.corpus}` -- {len(rows)} rows (vault={vault_n}, synthetic={synthetic_n}).
Language model data: `{args.data}/data.txt` (sha256 {sha256_of(args.data / "data.txt")}).

## Commands

```
cmake -S Source/Engine -B build-engine -DENABLE_TEST=ON
cmake --build build-engine
python3 tools/eval/run_eval.py --corpus {args.corpus} \\
    --cli {args.cli} --data {args.data}
```

## Results

### F1 -- English segment retention (mode `keys`)

Types each corpus row's full ASCII key sequence (Chinese Bopomofo keys and
English letters interleaved exactly as they would be typed, with no mode
switch) through the real KeyHandler-equivalent FSM, then checks whether
each gold English token still appears literally in the composed output.

| metric | value |
|---|---|
| token-level retention | {f1_retained_tokens}/{f1_total_tokens} = {f1_rate:.1f}% |
| row-level (all English tokens in row retained) | {f1_row_all_retained}/{len(rows)} = {f1_row_rate:.1f}% |
| latency (avg / p50 / p95 / max) | {statistics.mean(f1_latencies_us):.0f}us / {percentile(f1_latencies_us, 0.5):.0f}us / {percentile(f1_latencies_us, 0.95):.0f}us / {max(f1_latencies_us)}us |

This is expected to be near 0%: the current engine has no English-awareness
at all (see zhuyin-ime-personal.md's F1 scope). Every English letter is
also a valid standard-layout Bopomofo key, so an English word typed without
switching modes is either silently dropped (composition fails
`hasUnigrams`) or misrecognized as unrelated Chinese character(s) -- it is
essentially never coincidentally left as literal ASCII text.

### F2 -- homophone / candidate-selection accuracy (mode `readings`)

Feeds each row's gold Bopomofo readings for its zh segments only (no
English, no key-handling noise) and compares the resulting composed text
against the gold zh text, character by character.

| metric | value |
|---|---|
| char-level accuracy | {f2_correct_chars}/{f2_total_chars} = {f2_rate:.1f}% |
| rows with a length mismatch | {f2_length_mismatches}/{len(rows)} |
| latency (avg / p50 / p95 / max) | {statistics.mean(f2_latencies_us):.0f}us / {percentile(f2_latencies_us, 0.5):.0f}us / {percentile(f2_latencies_us, 0.95):.0f}us / {max(f2_latencies_us)}us |

This number is the unmodified ReadingGrid Viterbi walk's accuracy against
the corpus's gold characters -- i.e. how good the stock language model's
candidate ranking already is, independent of typing/segmentation. Any F2
regression after a future change (e.g. AI re-ranking in P2) should be
compared against this number.
"""
    args.baseline_out.write_text(baseline_md, encoding="utf-8")
    print(f"\nwrote {args.baseline_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
