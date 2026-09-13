#!/usr/bin/env python3
"""Run the P0.5 baseline eval over tools/eval's zh/en mixed-typing corpus.

This measures the *current* (pre-F1) engine's behavior, not a target: it
exists so future F1/F2 work has a number to beat, per the "Software 2.0"
principle of measuring before building.

Two independent metrics, both driven by the compiled bopomix-eval CLI so the
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
      --cli ./build-engine/tools/eval/bopomix-eval --data <ResourcesDir>
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


def run_cli_batch(
    cli: Path,
    data_dir: Path,
    mode: str,
    lines: list[str],
    mixed: bool = False,
    lexicon_dir: Path | None = None,
) -> list[list[str]]:
    if not lines:
        return []
    cmd = [str(cli), "--data", str(data_dir), "--mode", mode]
    if mixed:
        cmd += ["--mixed", "on", "--lexicon-dir", str(lexicon_dir)]
    proc = subprocess.run(
        cmd,
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


def compute_f1(cli: Path, data: Path, rows: list[dict], mixed: bool, lexicon_dir: Path | None) -> dict:
    keys_out = run_cli_batch(cli, data, "keys", [r["keys"] for r in rows], mixed, lexicon_dir)

    total_tokens = 0
    retained_tokens = 0
    latencies_us = []
    row_all_retained = 0
    failed_tokens: list[str] = []  # lowercased, one entry per failed occurrence
    for row, out in zip(rows, keys_out):
        composed, _uncomposable, latency_us = out[0], out[1], int(out[2])
        latencies_us.append(latency_us)
        en_tokens = [seg["text"] for seg in row["segments"] if seg["lang"] == "en"]
        composed_lower = composed.lower()
        row_all_ok = True
        for tok in en_tokens:
            total_tokens += 1
            if tok.lower() in composed_lower:
                retained_tokens += 1
            else:
                row_all_ok = False
                failed_tokens.append(tok.lower())
        if en_tokens and row_all_ok:
            row_all_retained += 1

    return {
        "total_tokens": total_tokens,
        "retained_tokens": retained_tokens,
        "rate": (retained_tokens / total_tokens * 100) if total_tokens else 0.0,
        "row_all_retained": row_all_retained,
        "row_rate": (row_all_retained / len(rows) * 100) if rows else 0.0,
        "latencies_us": latencies_us,
        "failed_tokens": failed_tokens,
    }


def compute_f2(cli: Path, data: Path, rows: list[dict], mixed: bool, lexicon_dir: Path | None) -> dict:
    reading_lines = []
    gold_texts = []
    for row in rows:
        reading_lines.append(row["readings"].replace("|", " "))
        gold_texts.append("".join(seg["text"] for seg in row["segments"] if seg["lang"] == "zh"))

    readings_out = run_cli_batch(cli, data, "readings", reading_lines, mixed, lexicon_dir)

    total_chars = 0
    correct_chars = 0
    latencies_us = []
    length_mismatches = 0
    for gold, out in zip(gold_texts, readings_out):
        composed, _insert_failures, latency_us = out[0], out[1], int(out[2])
        latencies_us.append(latency_us)
        if len(composed) != len(gold):
            length_mismatches += 1
        for i in range(min(len(gold), len(composed))):
            total_chars += 1
            if gold[i] == composed[i]:
                correct_chars += 1
        total_chars += max(0, len(gold) - len(composed))

    return {
        "total_chars": total_chars,
        "correct_chars": correct_chars,
        "rate": (correct_chars / total_chars * 100) if total_chars else 0.0,
        "length_mismatches": length_mismatches,
        "latencies_us": latencies_us,
    }


def classify_failed_tokens(
    cli: Path, data: Path, lexicon_dir: Path, failed_tokens: list[str]
) -> list[tuple[str, int, str]]:
    """For each distinct failed F1 token (mixed=on run), classifies *why* it
    did not survive by re-running it in isolation: "acer " (with a
    trailing space, the same boundary every corpus row's `keys` column
    already puts around an English segment -- see build_corpus.py). Three
    buckets:
      - "context interaction": survives fine alone -- something about its
        surrounding sentence (e.g. adjacent Bopomofo state) suppressed it,
        not the word itself. Worth a closer look; not expected to be common.
      - "ambiguous, not in dictionary": rule A's structural shape check
        (BopomofoShapeTracker) did not fire even in isolation, and the
        word is not in the lexicon either, so it fell all the way through
        to plain (wrong) Chinese composition.
      - "dictionary rank/registration issue": IS a known dictionary word
        (rule B should apply) but still failed even in isolation --
        signals an actual bug worth investigating, not a modeling gap.
    Returns (token, count, category) sorted by count descending, top 20.
    """
    counts: dict[str, int] = {}
    for tok in failed_tokens:
        counts[tok] = counts.get(tok, 0) + 1
    distinct = sorted(counts.items(), key=lambda kv: -kv[1])[:20]
    if not distinct:
        return []

    probe_lines = [f"{tok} " for tok, _ in distinct]
    probe_out = run_cli_batch(cli, data, "keys", probe_lines, mixed=True, lexicon_dir=lexicon_dir)

    results = []
    for (tok, count), out in zip(distinct, probe_out):
        composed = out[0].lower()
        if tok in composed:
            category = "上下文干擾（單獨測試可過）"
        else:
            category = "規則錯判／未命中詞典（獨立測試也失敗，需人工檢視）"
        results.append((tok, count, category))
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--baseline-out", type=Path, default=Path(__file__).resolve().parent / "BASELINE.md")
    parser.add_argument(
        "--mixed",
        choices=["on", "off"],
        default="off",
        help="Drive the CLI's --mixed on|off (P1 zh/en mixed typing). "
        "'off' (default) reproduces the P0.5 baseline unchanged and "
        "(re)writes --baseline-out. 'on' additionally appends a P1 "
        "results section to --baseline-out rather than overwriting it.",
    )
    parser.add_argument(
        "--lexicon-dir",
        type=Path,
        help="Directory with latin-words.txt/latin-tech-seed.txt (see "
        "Source/Data/ and tools/lexicon/build_lexicon.py). Required with --mixed on.",
    )
    args = parser.parse_args()

    mixed = args.mixed == "on"
    if mixed and args.lexicon_dir is None:
        print("error: --mixed on requires --lexicon-dir", file=sys.stderr)
        return 1

    rows = load_corpus(args.corpus)
    if not rows:
        print("error: corpus is empty", file=sys.stderr)
        return 1

    f1 = compute_f1(args.cli, args.data, rows, mixed, args.lexicon_dir)
    f2 = compute_f2(args.cli, args.data, rows, mixed, args.lexicon_dir)

    f1_total_tokens = f1["total_tokens"]
    f1_retained_tokens = f1["retained_tokens"]
    f1_rate = f1["rate"]
    f1_row_all_retained = f1["row_all_retained"]
    f1_row_rate = f1["row_rate"]
    f1_latencies_us = f1["latencies_us"]

    f2_total_chars = f2["total_chars"]
    f2_correct_chars = f2["correct_chars"]
    f2_rate = f2["rate"]
    f2_length_mismatches = f2["length_mismatches"]
    f2_latencies_us = f2["latencies_us"]

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
        f"mixed: {args.mixed}",
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

    if mixed:
        # P1 (see zhuyin-ime-personal.md): append to the existing
        # BASELINE.md rather than overwriting it, so the P0.5 baseline
        # numbers above stay intact for comparison. Run with --mixed off
        # first (the default) to (re)generate that baseline section.
        failed_categorized = classify_failed_tokens(
            args.cli, args.data, args.lexicon_dir, f1["failed_tokens"]
        )
        if failed_categorized:
            failure_table = "\n".join(
                f"| {tok} | {count} | {category} |" for tok, count, category in failed_categorized
            )
        else:
            failure_table = "| (none) | - | all F1 tokens survived |"

        p1_md = f"""

## P1 -- engine-only (no KeyHandler; engine regression only)

Generated: {datetime.datetime.now().astimezone().isoformat(timespec='seconds')}

Same corpus and language model as the P0.5 baseline above, run with
`--mixed on` (Source/Engine/MixedScript/, see
~/.claude/plans/zhuyin-ime-personal.md's P1 design section) instead of the
baseline's unmodified engine.

**These numbers are not acceptance criteria.** `bopomix-eval` reimplements
the *ordering* of KeyHandler.mm's operations over the same engine; it has
no candidate window, no Esc/backspace handling, no force-commit and no
user override model, so it cannot see the class of defect that made the
first P1 round unshippable. The acceptance measurement is the app-path
section at the end of this file, produced by
`MixedScriptKeyHandlerTests.testEval200ThroughKeyHandler`. Keep this
section as an engine regression check only.

### Commands

```
python3 tools/eval/run_eval.py --corpus {args.corpus} \\
    --cli {args.cli} --data {args.data} \\
    --mixed on --lexicon-dir {args.lexicon_dir}
```

### F1 -- English segment retention (mode `keys`, mixed=on, engine-only)

| metric | value |
|---|---|
| token-level retention | {f1_retained_tokens}/{f1_total_tokens} = {f1_rate:.1f}% |
| row-level (all English tokens in row retained) | {f1_row_all_retained}/{len(rows)} = {f1_row_rate:.1f}% |
| latency (avg / p50 / p95 / max) | {statistics.mean(f1_latencies_us):.0f}us / {percentile(f1_latencies_us, 0.5):.0f}us / {percentile(f1_latencies_us, 0.95):.0f}us / {max(f1_latencies_us)}us |

### F2 -- homophone/candidate-selection accuracy (mode `readings`, mixed=on, engine-only)

Expected to be unchanged from the P0.5 baseline above -- rule B only adds a
low-scored alternate candidate at an existing reading's node (see
LatinPassthroughLM), it never changes what the *Chinese* candidate for a
reading is or its score, and `readings` mode never touches
BopomofoReadingBuffer/MixedScriptTracker in the first place (see
tools/eval/README.md's mode description) -- only `keys` mode does.

| metric | value |
|---|---|
| char-level accuracy | {f2_correct_chars}/{f2_total_chars} = {f2_rate:.1f}% |
| rows with a length mismatch | {f2_length_mismatches}/{len(rows)} |
| latency (avg / p50 / p95 / max) | {statistics.mean(f2_latencies_us):.0f}us / {percentile(f2_latencies_us, 0.5):.0f}us / {percentile(f2_latencies_us, 0.95):.0f}us / {max(f2_latencies_us)}us |

### F1 failures, top {min(20, len(failed_categorized)) if failed_categorized else 0} by frequency, categorized

Categorization method: each distinct failed token is re-run *alone* (with
the same trailing space every corpus row's `keys` column already puts
after an English segment). If it survives alone, the failure is
context-dependent (something about the surrounding sentence, not the word
itself); if it still fails alone, either the shape/dictionary rules
genuinely do not cover it, or there is a bug -- see the category column.

| token | count (out of {f1_total_tokens} total tokens) | category |
|---|---|---|
{failure_table}

"""
        existing = args.baseline_out.read_text(encoding="utf-8") if args.baseline_out.exists() else ""
        args.baseline_out.write_text(existing.rstrip("\n") + "\n" + p1_md, encoding="utf-8")
        print(f"\nappended P1 section to {args.baseline_out}")
        return 0

    baseline_md = f"""# bopomix P0.5 baseline

Generated: {datetime.datetime.now().astimezone().isoformat(timespec='seconds')}

Engine: bopomix (fork of McBopomofo, upstream commit f5ba010 at fork time),
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

### F1 -- English segment retention (mode `keys`, engine-only)

Types each corpus row's full ASCII key sequence (Chinese Bopomofo keys and
English letters interleaved exactly as they would be typed, with no mode
switch) through the engine's key-handling order (a *re-implementation* of
KeyHandler.mm's ordering, not KeyHandler itself), then checks whether
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

### F2 -- homophone / candidate-selection accuracy (mode `readings`, engine-only)

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
