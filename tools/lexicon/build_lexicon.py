#!/usr/bin/env python3
"""Builds Source/Data/latin-words.txt for the zh/en mixed-typing feature
(see ~/.claude/plans/zhuyin-ime-personal.md's "P1 設計"/"P3 設計" sections
and Source/Engine/MixedScript/latin_lexicon.h).

Source: macOS's bundled BSD word list (/usr/share/dict/words -- see
ACKNOWLEDGEMENTS.md for its license). Filtering:
  - keep only lines that are entirely lowercase ASCII letters (a-z); this
    both excludes proper nouns (the BSD list capitalizes them) and excludes
    apostrophe'd contractions/possessives, matching the standard-layout
    Bopomofo key set MixedScriptTracker operates on (letters only).
  - length 2-15 (2: MixedScriptTracker::kMinAmbiguousWordLength never
    considers shorter runs anyway; 15: matches ReadingGrid's own
    kMaximumSpanLength-adjacent scale and rules out the word list's long
    tail of compounds/technical Latin that are vanishingly unlikely to be
    typed as a Bopomofo-mode English run).

The output is written in sorted order, and that is load-bearing, not
cosmetic: LatinLexicon keeps its isPrefix()/complete() index ordered as the
file loads, which is a linear merge for a pre-sorted file and a full sort
otherwise. Emitting an unsorted list still works, it just moves ~200k
words' worth of sorting into the load.

Frequency ranks (P3, tools/lexicon/scowl-size-tiers.tsv): P1 shipped with no
rank data -- this repo did not have a license-clear (MIT/BSD/CC0/public-
domain) frequency source available to verify at the time (CC-BY-SA sources
such as most Wiktionary-derived lists do not qualify; nor does
first20hours/google-10000-english, whose LICENSE.md ties the underlying
Google/LDC n-gram corpus to a research/fair-use grant and explicitly
disclaims commercial redistribution rights). SCOWL/ESDB (the "Spell Checker
Oriented Word Lists" project, https://github.com/en-wl/wordlist) *is*
license-clear for a generated word list of size <=80 -- its Copyright file
grants "permission to use, copy, modify, distribute, and sell any part of
the [ESDB], or word lists created from it ... without fee" (see
ACKNOWLEDGEMENTS.md for the full notice this script's output must ship
with) -- so this script now uses SCOWL's cumulative size buckets (35, 40,
50, 60, 70, 80; each is a superset of the smaller ones, so "the smallest
bucket a word first appears in" is a coarse but real commonality signal) as
a frequency-rank *tier*: 0 = appears by size 35 (most common) .. 5 =
appears only by size 80 (least common of the sizes used). This is the
"依 SCOWL 桶" fallback the P3 spec allows when no word-level frequency
number is available -- it is deliberately coarse (tens of thousands of
words share a tier) rather than pretending to more precision than the
source has; LatinLexicon::complete() breaks ties alphabetically.

scowl-size-tiers.tsv ships pre-generated (word<TAB>tier, trimmed to just
the words already in this script's own dictionary output -- it is a rank
*annotation*, not a second word-list source) rather than being rebuilt on
every run, since producing it means cloning and `make`-building the ~130MB
ESDB sqlite database. To regenerate it after changing --source or the
SCOWL data:
    git clone --depth 1 -b v2 https://github.com/en-wl/wordlist.git
    cd wordlist && make   # builds scowl.db (Python 3 + sqlite3 required)
    for sz in 35 40 50 60 70 80; do
      ./scowl --db scowl.db word-list $sz A 1 --categories= > scowl-$sz.txt
    done
Then, for each word passing this script's own lowercase-ASCII/length
filter, take the smallest `sz` whose list contains it as that word's tier,
and write "word<TAB>tier" sorted by word for every word also present in
this script's dictionary output.

Words with no SCOWL tier (the long tail of Webster's 1934 entries SCOWL
doesn't carry, ~61% of the dictionary) are left unranked, exactly as
before -- LatinLexicon.loadBuiltinWordList() assigns those ranks by file
order (alphabetical), which is not a frequency signal but keeps every
previously-known word in the dictionary rather than shrinking it to only
what SCOWL covers.

Source/Data/latin-tech-seed.txt's hand-picked, explicitly-ranked terms
still take priority over both: LanguageModelManager loads it *before* this
script's output, and loadBuiltinWordList() offsets each later file's
explicit ranks past whatever range the earlier file already claimed (see
its comment), so tech-seed words always outrank dictionary words
regardless of the dictionary word's own tier.

Usage:
    python3 tools/lexicon/build_lexicon.py \
        --source /usr/share/dict/words \
        --output Source/Data/latin-words.txt \
        --freq-tiers tools/lexicon/scowl-size-tiers.tsv
"""

import argparse
import pathlib
import re
import sys

LOWERCASE_WORD_RE = re.compile(r"^[a-z]+$")


def load_freq_tiers(path: pathlib.Path) -> dict:
    tiers = {}
    if path is None or not path.exists():
        return tiers
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            word, tier = line.split("\t")
            tiers[word] = int(tier)
    return tiers


def build(
    source: pathlib.Path,
    output: pathlib.Path,
    min_len: int,
    max_len: int,
    freq_tiers: dict,
) -> tuple[int, int]:
    words = set()
    with source.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            word = line.strip()
            if not word:
                continue
            if not LOWERCASE_WORD_RE.match(word):
                continue
            if not (min_len <= len(word) <= max_len):
                continue
            words.add(word)

    sorted_words = sorted(words)
    ranked_count = sum(1 for word in sorted_words if word in freq_tiers)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        f.write(
            "# Generated by tools/lexicon/build_lexicon.py from "
            f"{source} ({len(sorted_words)} words, {ranked_count} with a "
            "SCOWL frequency-tier rank -- see that script's docstring and\n"
            "# ACKNOWLEDGEMENTS.md). Do not hand-edit; see the docstring "
            "for filtering rules and the source lists' licenses.\n"
        )
        for word in sorted_words:
            tier = freq_tiers.get(word)
            if tier is None:
                f.write(word + "\n")
            else:
                f.write(f"{word}\t{tier}\n")
    return len(sorted_words), ranked_count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path, default=pathlib.Path("/usr/share/dict/words"))
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[2] / "Source" / "Data" / "latin-words.txt",
    )
    parser.add_argument(
        "--freq-tiers",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent / "scowl-size-tiers.tsv",
        help="word<TAB>tier file (0=most common); pass a nonexistent path to disable ranking.",
    )
    parser.add_argument("--min-len", type=int, default=2)
    parser.add_argument("--max-len", type=int, default=15)
    args = parser.parse_args()

    if not args.source.exists():
        print(f"error: source word list not found: {args.source}", file=sys.stderr)
        return 1

    freq_tiers = load_freq_tiers(args.freq_tiers)
    count, ranked_count = build(args.source, args.output, args.min_len, args.max_len, freq_tiers)
    print(f"wrote {count} words ({ranked_count} ranked) to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
