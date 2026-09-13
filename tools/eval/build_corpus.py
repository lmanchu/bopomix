#!/usr/bin/env python3
"""Build tools/eval's 200-sentence chat-style zh/en mixed-typing eval corpus.

Reads candidate sentences from a private, out-of-repo file (see
--candidates; defaults to ~/Dev/mixime-private/corpus_candidates.txt, which
is mostly AI-generated summaries and Slack/gmail text, NOT sentences Lman
actually typed), filters them down to short, colloquial, zh/en-mixed chat
sentences, and pads the remainder up to --target with synthetic sentences
generated from templates (clearly tagged source=synthetic).

For each surviving sentence, this script:
  1. Normalizes it to CJK ideographs + ASCII letters + single spaces only
     (punctuation, digits, URLs, Slack mentions, markdown noise stripped),
     because the corpus's `segments` schema only distinguishes "zh"/"en".
  2. Splits it into ordered zh/en segments.
  3. Calls the compiled bopomix-eval CLI in `keyseq` mode (once, batched over
     every zh segment in the whole corpus) to get each zh segment's
     Bopomofo readings and standard-layout key sequence -- this script does
     NOT reimplement a keyboard map or a reading dictionary.
  4. Writes id / sentence / segments (JSON) / readings / keys / source to
     the output TSV.

Privacy: the output TSV can contain Lman's own text (via the vault-derived
candidates) and MUST stay under ~/Dev/mixime-private/ (see repo .gitignore's
`*.private.*` rule and tools/eval/README.md). Only tools/eval/fixtures/
sample10.tsv (synthetic-only, 10 rows) is meant to ever enter this repo.
"""

from __future__ import annotations

import argparse
import itertools
import json
import random
import re
import subprocess
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

COLLOQUIAL_MARKERS = [
    "我", "你", "這", "那", "了", "吧", "嗎", "可以", "要", "先", "再", "就",
]

# Applied to the *raw* candidate line, before normalization. These catch
# structural noise (lists, headings, IDs, links) that a chat sentence would
# not contain, even after the rest of the pipeline strips punctuation/digits.
REJECT_PATTERNS = [
    re.compile(r"https?://"),                 # URLs
    re.compile(r"<[^>]*>"),                   # HTML tags / Slack <@Uxxxx> mentions
    re.compile(r"\*\*"),                      # markdown bold (list/label headers)
    re.compile(r"^\s*[-*•]\s"),               # bullet list item
    re.compile(r"^\s*\d+[.)、]\s"),           # numbered list item ("1. ", "10) ")
    re.compile(r"^\s*\[[^\]]*\]"),            # "[ ] task" / "[#channel]" prefixes
    re.compile(r"^[^\s:：]{1,14}[:：]"),       # "Label: value" / "標題：內容" heading
    re.compile(r"[A-Za-z]{1,4}-\d"),          # ID-code fragments, e.g. "AR-260902"
    re.compile(r"\d{4,}"),                    # dates / phone / invoice numbers
]

CJK_RUN_RE = re.compile(r"[一-鿿]+")
EN_RUN_RE = re.compile(r"[A-Za-z]+")
KEEP_CHARS_RE = re.compile(r"[^一-鿿A-Za-z ]")
MIN_LEN, MAX_LEN = 12, 60
MIN_CJK_CHARS = 6
MIN_EN_TOKENS, MAX_EN_TOKENS = 1, 3


def normalize(line: str) -> str:
    """Keep only CJK ideographs, ASCII letters, and single spaces."""
    stripped = KEEP_CHARS_RE.sub(" ", line)
    return re.sub(r"\s+", " ", stripped).strip()


def passes_raw_filters(line: str) -> bool:
    if any(p.search(line) for p in REJECT_PATTERNS):
        return False
    if not any(marker in line for marker in COLLOQUIAL_MARKERS):
        return False
    return True


def passes_normalized_filters(norm: str) -> tuple[bool, str]:
    if not (MIN_LEN <= len(norm) <= MAX_LEN):
        return False, f"length {len(norm)} outside [{MIN_LEN},{MAX_LEN}]"
    cjk_chars = sum(len(m) for m in CJK_RUN_RE.findall(norm))
    if cjk_chars < MIN_CJK_CHARS:
        return False, f"only {cjk_chars} CJK chars"
    en_tokens = [t for t in EN_RUN_RE.findall(norm) if 2 <= len(t) <= 15]
    if not (MIN_EN_TOKENS <= len(en_tokens) <= MAX_EN_TOKENS):
        return False, f"{len(en_tokens)} English tokens"
    if not any(marker in norm for marker in COLLOQUIAL_MARKERS):
        return False, "no colloquial marker survived normalization"
    return True, ""


def segment(norm: str) -> list[dict]:
    """Split a normalized (CJK + ASCII-letters + space only) sentence into
    ordered {"text","lang"} segments. Spaces are separators only and are
    dropped from segment text."""
    segments: list[dict] = []
    i = 0
    n = len(norm)
    while i < n:
        ch = norm[i]
        if ch == " ":
            i += 1
            continue
        if ch.isascii() and ch.isalpha():
            m = EN_RUN_RE.match(norm, i)
            segments.append({"text": m.group(0), "lang": "en"})
            i = m.end()
        else:
            m = CJK_RUN_RE.match(norm, i)
            if m:
                segments.append({"text": m.group(0), "lang": "zh"})
                i = m.end()
            else:
                # Shouldn't happen after normalize(), but stay safe.
                i += 1
    return segments


# ---------------------------------------------------------------------------
# Synthetic sentence generation (used to pad up to --target)
# ---------------------------------------------------------------------------

EN_TOKENS = [
    "Mac", "Slack", "PR", "API", "IrisGo", "OpenRouter", "GitHub", "Notion",
    "Zoom", "Xcode", "demo", "bug", "repo", "commit", "deploy", "cache",
    "token", "prompt", "agent", "model", "build", "merge", "review",
    "sprint", "CLI", "CI", "UI", "UX", "PM", "OKR",
]

SYNTHETIC_TEMPLATES = [
    "我先把{en}的問題修一下再給你看",
    "這個{en}你要先跑一次才知道對不對",
    "可以先幫我看一下{en}那邊是不是壞了",
    "我這邊{en}一直卡住了，你那邊也一樣嗎",
    "那個{en}我先擱著，明天再處理就好",
    "你先把{en}那份文件看完，我們再討論",
    "我要先確認{en}的結果，才能跟你回報",
    "這次的{en}我打算先做完再上線",
    "你可以先開{en}看一下，我等一下就過去",
    "我先把{en}關掉，等一下再打開就好了",
    "這樣改{en}你覺得可以嗎，我再調一次",
    "我先去開個{en}，你先幫我盯著這邊",
    "那份{en}我先存好了，你要的話再傳給你",
    "我這禮拜先把{en}弄完，下週再驗收",
    "你先試試看{en}這個版本，我再看看反饋",
    "我先睡了，{en}的事我們明天再談吧",
    "這個{en}的邏輯我先理清楚再動手改",
    "你要不要先開{en}，我們邊看邊聊",
    "我先把{en}的資料整理好，你再確認一下",
    "那我們就先用這版{en}，之後再優化吧",
]


def generate_synthetic(count: int, avoid: set[str]) -> list[str]:
    if count <= 0:
        return []
    rng = random.Random(20260908)
    pool: list[str] = []
    for template, en in itertools.product(SYNTHETIC_TEMPLATES, EN_TOKENS):
        candidate = template.format(en=en)
        norm = normalize(candidate)
        ok, _ = passes_normalized_filters(norm)
        if ok and norm not in avoid:
            pool.append(norm)
    rng.shuffle(pool)
    seen: set[str] = set()
    result: list[str] = []
    for norm in pool:
        if norm in seen:
            continue
        seen.add(norm)
        result.append(norm)
        if len(result) >= count:
            break
    return result


# ---------------------------------------------------------------------------
# keyseq CLI batching
# ---------------------------------------------------------------------------


def resolve_readings_and_keys(cli: Path, data_dir: Path, rows: list[dict]) -> tuple[list[dict], int]:
    """Populates each row's "readings"/"keys" fields via one batched keyseq
    call. Rows containing a character with no dictionary reading are
    dropped (not written with a placeholder) so the corpus stays clean.
    Returns (kept_rows, dropped_count), preserving input order."""
    for row in rows:
        row["segments"] = segment(row["sentence"])

    all_zh_segments: list[str] = []
    zh_index: list[tuple[int, int]] = []  # (row_idx, segment_idx)
    for ri, row in enumerate(rows):
        for si, seg in enumerate(row["segments"]):
            if seg["lang"] == "zh":
                all_zh_segments.append(seg["text"])
                zh_index.append((ri, si))

    keyseq_results = run_keyseq_batch(cli, data_dir, all_zh_segments)

    per_segment_readings: dict[tuple[int, int], str] = {}
    per_segment_keys: dict[tuple[int, int], str] = {}
    for (ri, si), (readings, keys) in zip(zh_index, keyseq_results):
        per_segment_readings[(ri, si)] = readings
        per_segment_keys[(ri, si)] = keys

    kept: list[dict] = []
    dropped = 0
    for ri, row in enumerate(rows):
        has_unknown = any(
            "_unknown_" in per_segment_readings.get((ri, si), "")
            for si, seg in enumerate(row["segments"])
            if seg["lang"] == "zh"
        )
        if has_unknown:
            dropped += 1
            continue
        readings_parts = []
        keys_parts = []
        for si, seg in enumerate(row["segments"]):
            if seg["lang"] == "zh":
                readings_parts.append(per_segment_readings[(ri, si)])
                keys_parts.append(per_segment_keys[(ri, si)])
            else:
                keys_parts.append(seg["text"].lower())
        row["readings"] = "|".join(readings_parts)
        row["keys"] = " ".join(keys_parts)
        kept.append(row)
    return kept, dropped


def write_tsv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for i, row in enumerate(rows, start=1):
            f.write(
                "\t".join(
                    [
                        str(i),
                        row["sentence"],
                        json.dumps(row["segments"], ensure_ascii=False),
                        row["readings"],
                        row["keys"],
                        row["source"],
                    ]
                )
                + "\n"
            )


def run_keyseq_batch(cli: Path, data_dir: Path, zh_segments: list[str]) -> list[tuple[str, str]]:
    """Runs `bopomix-eval --mode keyseq` once over every zh segment across the
    whole corpus and returns a parallel list of (readings, keys)."""
    if not zh_segments:
        return []
    proc = subprocess.run(
        [str(cli), "--data", str(data_dir), "--mode", "keyseq"],
        input="\n".join(zh_segments) + "\n",
        capture_output=True,
        text=True,
        check=True,
    )
    lines = proc.stdout.rstrip("\n").split("\n")
    if len(lines) != len(zh_segments):
        raise RuntimeError(
            f"keyseq mode returned {len(lines)} lines for {len(zh_segments)} "
            f"input segments (stderr: {proc.stderr.strip()[:500]})"
        )
    out = []
    for line in lines:
        readings, _, keys = line.partition("\t")
        out.append((readings, keys))
    return out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--candidates",
        type=Path,
        default=Path("~/Dev/mixime-private/corpus_candidates.txt").expanduser(),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("~/Dev/mixime-private/eval200.tsv").expanduser(),
    )
    parser.add_argument("--cli", type=Path, required=True, help="path to bopomix-eval")
    parser.add_argument("--data", type=Path, required=True, help="Resources dir with data.txt")
    parser.add_argument("--target", type=int, default=200)
    parser.add_argument(
        "--fixtures-out",
        type=Path,
        default=Path(__file__).resolve().parent / "fixtures" / "sample10.tsv",
        help="repo-safe synthetic-only sample written alongside the private corpus",
    )
    args = parser.parse_args()

    if not args.candidates.exists():
        print(f"error: candidates file not found: {args.candidates}", file=sys.stderr)
        return 1

    raw_lines = [
        line.strip()
        for line in args.candidates.read_text(encoding="utf-8", errors="replace").splitlines()
        if line.strip()
    ]
    total_candidates = len(raw_lines)

    accepted: list[str] = []
    seen_norm: set[str] = set()
    rejects = {"raw_filter": 0, "normalized_filter": 0, "duplicate": 0}
    for line in raw_lines:
        if not passes_raw_filters(line):
            rejects["raw_filter"] += 1
            continue
        norm = normalize(line)
        ok, _reason = passes_normalized_filters(norm)
        if not ok:
            rejects["normalized_filter"] += 1
            continue
        if norm in seen_norm:
            rejects["duplicate"] += 1
            continue
        seen_norm.add(norm)
        accepted.append(norm)

    vault_count = len(accepted)
    # Build a slate a bit larger than --target so that rows dropped later
    # (e.g. for an out-of-dictionary character in keyseq mode) can be
    # backfilled from the same pool without a second CLI invocation.
    buffer = 30
    needed_synthetic = max(0, (args.target + buffer) - vault_count)
    synthetic_pool = generate_synthetic(needed_synthetic, avoid=seen_norm)
    if needed_synthetic and len(synthetic_pool) < needed_synthetic:
        print(
            f"warning: only generated {len(synthetic_pool)}/{needed_synthetic} "
            "synthetic sentences (template x token pool exhausted after dedup)",
            file=sys.stderr,
        )

    rows: list[dict] = []
    for norm in accepted:
        rows.append({"sentence": norm, "source": "vault"})
    for norm in synthetic_pool:
        rows.append({"sentence": norm, "source": "synthetic"})
    # Keep a generous slate (target + buffer) so a few keyseq drops still
    # leave enough clean rows to reach exactly --target.
    rows = rows[: args.target + buffer]

    final_rows, dropped_unknown = resolve_readings_and_keys(args.cli, args.data, rows)
    final_rows = final_rows[: args.target]
    if len(final_rows) < args.target:
        print(
            f"warning: dropped {dropped_unknown} row(s) with an unknown "
            f"character and the buffer was not big enough to backfill; "
            f"corpus has {len(final_rows)}/{args.target} rows",
            file=sys.stderr,
        )

    write_tsv(args.output, final_rows)

    # tools/eval/fixtures/sample10.tsv is a repo-committed, synthetic-only
    # sample (see .gitignore's *.private.* rule and the module docstring).
    # It is generated independently of whether eval200.tsv itself needed any
    # synthetic padding, so it always has 10 rows.
    fixture_sentences = generate_synthetic(
        10, avoid=seen_norm | {r["sentence"] for r in rows}
    )
    fixture_rows = [{"sentence": s, "source": "synthetic"} for s in fixture_sentences]
    fixture_rows, fixture_dropped = resolve_readings_and_keys(args.cli, args.data, fixture_rows)
    if len(fixture_rows) < 10:
        print(
            f"warning: only {len(fixture_rows)}/10 fixture rows survived "
            f"keyseq ({fixture_dropped} dropped for unknown character)",
            file=sys.stderr,
        )
    write_tsv(args.fixtures_out, fixture_rows)

    vault_final = sum(1 for r in final_rows if r["source"] == "vault")
    synthetic_final = sum(1 for r in final_rows if r["source"] == "synthetic")
    print(f"candidates read: {total_candidates}")
    print(f"rejected by raw filters (list/heading/ID/URL/no-marker): {rejects['raw_filter']}")
    print(f"rejected by normalized filters (length/CJK/en-token-count): {rejects['normalized_filter']}")
    print(f"rejected as duplicate: {rejects['duplicate']}")
    print(f"accepted from vault: {vault_count}")
    print(f"synthetic generated for main slate: {len(synthetic_pool)}")
    print(f"dropped for unknown character in keyseq: {dropped_unknown}")
    print(f"final corpus rows: {len(final_rows)} (vault={vault_final}, synthetic={synthetic_final})")
    print(f"wrote: {args.output}")
    print(f"wrote fixture sample: {args.fixtures_out} ({len(fixture_rows)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
