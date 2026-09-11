#!/usr/bin/env python3
"""Builds Source/Data/latin-words.txt for the zh/en mixed-typing feature
(see ~/.claude/plans/zhuyin-ime-personal.md's "P1 設計"/"P3 設計" sections
and Source/Engine/MixedScript/latin_lexicon.h).

Source (2026-09-11 P3 fix-round rework): SCOWL/ESDB itself (the "Spell
Checker Oriented Word Lists" project by Kevin Atkinson,
https://github.com/en-wl/wordlist) is now the word list's *body*, not just
a frequency annotation layered on a different source the way the first P3
round did it. That first round kept macOS's bundled `/usr/share/dict/words`
(a symlink to `web2`, i.e. Webster's Second International Dictionary, 1934)
as the dictionary and only used SCOWL to rank it -- but web2 has no
inflected forms at all ("games"/"typing"/"comments" are all missing, only
their lemmas are present) and nothing from the last ~90 years of
vocabulary. SCOWL's word lists carry both, so this script now generates the
word set itself from SCOWL too. web2 is no longer used anywhere in this
repo; see ACKNOWLEDGEMENTS.md for the license note this generated file
ships under (SCOWL/ESDB's "generated word list" grant, same text as
before, now covering the word set as well as the tiers).

Word set and frequency ranks both come from SCOWL's cumulative
"size" buckets for American-English, mainstream-spelling-variant words
(`./scowl --db scowl.db word-list SIZE A 1 --categories=`, invoked once per
size in --tier-sizes below): the largest size in that list defines the
dictionary's word set, and a word's rank tier is the index of the smallest
size it already appears in (0 = appears by the smallest/most-common size,
i.e. most frequent) -- the same coarse "which size bucket first contains
this word" signal the first P3 round introduced, just computed directly
from the word list's own source now instead of a separately-shipped
annotation file. Every word in the output has a tier (there is no more
"unranked, sorted alphabetically instead" tail): that tail was entirely an
artifact of pulling the word *set* from web2, which SCOWL's own tier data
did not fully cover.

Filtering, applied to every raw SCOWL entry before it is kept: lowercase
it, keep only entries that are then entirely `[a-z]` (this rejects
anything with digits, spaces, or an apostrophe -- e.g. SCOWL's
possessive/contraction entries like "AA's" -- in the same regex pass), and
require length 2-20 (2: MixedScriptTracker::kMinAmbiguousWordLength never
considers shorter runs anyway; 20: SCOWL's compound/technical long tail
past this is vanishingly unlikely to be typed as a Bopomofo-mode English
run -- widened from the old web2-based script's 15 now that the source
itself already excludes most of that long tail by size 70).

Regenerating requires a local clone of the SCOWL/ESDB repository, built
into its sqlite database (Python 3 and sqlite3 on PATH, ~130 MB result):
    git clone --depth 1 -b v2 https://github.com/en-wl/wordlist.git
    cd wordlist && make   # builds wordlist/scowl.db
Then, from this repo:
    python3 tools/lexicon/build_lexicon.py --scowl-repo /path/to/wordlist

This shells out to <scowl-repo>/scowl (SCOWL's own query CLI) once per
--tier-sizes entry rather than querying scowl.db directly, so a future
SCOWL schema change stays compatible without this script needing to track
it. Each call runs `./scowl --db scowl.db word-list SIZE A 1
--categories=` -- American spelling ("A"), variant level <=1 (mainstream
spellings only, no "uncommon"/"archaic" variants), no extra categories
(proper names, hacker slang, etc. are all separate SCOWL categories this
deliberately does not request -- see ACKNOWLEDGEMENTS.md's note on why the
general Copyright-file grant is enough without also triggering its
AU/UKACD-specific clauses).

Source/Data/latin-tech-seed.txt's hand-picked, explicitly-ranked terms
still take priority over this file: LanguageModelManager loads it *before*
this script's output, and LatinLexicon::loadBuiltinWordList() offsets each
later file's explicit ranks past whatever range the earlier file already
claimed (see its comment), so tech-seed words always outrank dictionary
words regardless of the dictionary word's own tier.

The output is written in sorted order, and that is load-bearing, not
cosmetic: LatinLexicon keeps its isPrefix()/complete() index ordered as the
file loads, which is a linear merge for a pre-sorted file and a full sort
otherwise.

Usage:
    python3 tools/lexicon/build_lexicon.py \
        --scowl-repo /path/to/wordlist \
        --output Source/Data/latin-words.txt
"""

import argparse
import pathlib
import re
import subprocess
import sys

LOWERCASE_WORD_RE = re.compile(r"^[a-z]+$")

DEFAULT_TIER_SIZES = (35, 40, 50, 60, 70)


def fetch_scowl_words(scowl_bin: pathlib.Path, scowl_db: pathlib.Path, size: int) -> set:
    """Runs SCOWL's own `scowl` query CLI for one cumulative size bucket
    (American spelling, variant level <=1, no extra categories -- see this
    module's docstring) and returns its raw (un-filtered, original-case)
    word set."""
    result = subprocess.run(
        [str(scowl_bin), "--db", str(scowl_db), "word-list", str(size), "A", "1", "--categories="],
        cwd=str(scowl_bin.parent),
        capture_output=True,
        text=True,
        check=True,
    )
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def normalize(word: str, min_len: int, max_len: int):
    lowered = word.lower()
    if not LOWERCASE_WORD_RE.match(lowered):
        return None
    if not (min_len <= len(lowered) <= max_len):
        return None
    return lowered


def build(
    scowl_bin: pathlib.Path,
    scowl_db: pathlib.Path,
    output: pathlib.Path,
    tier_sizes: list,
    min_len: int,
    max_len: int,
) -> int:
    tiers = {}
    for tier_index, size in enumerate(tier_sizes):
        raw_words = fetch_scowl_words(scowl_bin, scowl_db, size)
        for raw in raw_words:
            word = normalize(raw, min_len, max_len)
            if word is None or word in tiers:
                continue
            tiers[word] = tier_index

    sorted_words = sorted(tiers)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        f.write(
            "# Generated by tools/lexicon/build_lexicon.py from SCOWL/ESDB "
            f"(size<={tier_sizes[-1]}, American spelling, variant level <=1) -- "
            f"{len(sorted_words)} words, every one carrying a SCOWL size-bucket "
            "frequency-tier rank (0-" + str(len(tier_sizes) - 1) + "). Do not "
            "hand-edit; see the docstring for filtering rules and "
            "ACKNOWLEDGEMENTS.md for the source's license.\n"
        )
        for word in sorted_words:
            f.write(f"{word}\t{tiers[word]}\n")
    return len(sorted_words)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--scowl-repo",
        type=pathlib.Path,
        required=True,
        help=(
            "path to a `git clone --depth 1 -b v2 "
            "https://github.com/en-wl/wordlist.git` checkout that has been "
            "`make`-built (see this script's docstring for the exact steps)."
        ),
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[2] / "Source" / "Data" / "latin-words.txt",
    )
    parser.add_argument(
        "--tier-sizes",
        type=str,
        default=",".join(str(s) for s in DEFAULT_TIER_SIZES),
        help=(
            "comma-separated cumulative SCOWL sizes, smallest (most common) "
            "first; the largest one defines the dictionary's word set."
        ),
    )
    parser.add_argument("--min-len", type=int, default=2)
    parser.add_argument("--max-len", type=int, default=20)
    args = parser.parse_args()

    scowl_repo = args.scowl_repo.resolve()
    scowl_bin = scowl_repo / "scowl"
    scowl_db = scowl_repo / "scowl.db"
    if not scowl_bin.exists() or not scowl_db.exists():
        print(
            f"error: {scowl_repo} does not look like a built SCOWL/ESDB "
            "checkout (missing scowl or scowl.db -- see this script's "
            "docstring for how to clone and `make` one)",
            file=sys.stderr,
        )
        return 1

    tier_sizes = [int(s) for s in args.tier_sizes.split(",")]
    count = build(scowl_bin, scowl_db, args.output, tier_sizes, args.min_len, args.max_len)
    print(f"wrote {count} words (all ranked, tiers 0-{len(tier_sizes) - 1}) to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
