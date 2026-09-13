# bopomix eval harness (P0.5)

Headless tooling to measure the engine's zh/en mixed-typing behavior
without an installed input method, per `~/.claude/plans/zhuyin-ime-personal.md`'s
"build the harness before the feature" principle. Everything here talks to
the *real* C++ engine (`Source/Engine/`) -- nothing is re-implemented in
Python; Python only orchestrates the compiled CLI and does filtering/scoring.

Only the standard ("大千"/Da Chien) keyboard layout is supported right now.

## Building

```
cmake -S Source/Engine -B build-engine -DENABLE_TEST=ON
cmake --build build-engine
ctest --test-dir build-engine   # optional: engine's own gtest suite
```

This produces `build-engine/tools/eval/bopomix-eval`.

You need a `data.txt` (McBopomofo's compiled dictionary) to run it. A build
of upstream McBopomofo already has one at
`build/Build/Products/Debug/Bopomix.app/Contents/Resources/`
or build bopomix's own `Bopomix` Xcode target for a fresh copy. Only
`data.txt` is needed (not `data-plain-bpmf.txt` or
`associated-phrases-v2.txt`); pass its containing directory as `--data`.

## `bopomix-eval` CLI

```
bopomix-eval --data <ResourcesDir> --mode {keys|readings|keyseq} [--layout standard]
    [--mixed on|off] [--lexicon-dir <dir>]
```

`--mixed on` (P1, see `zhuyin-ime-personal.md`'s P1 design section) drives
`keys` mode through the same `Source/Engine/MixedScript/` decision engine
KeyHandler.mm uses for zh/en mixed typing -- rule A (structurally
impossible Bopomofo shape) and rule B (dictionary word, which only adds a
Latin candidate; a trailing space promotes it to English only for words in
the *user's own* lexicon, which this harness never loads). It is a no-op
for `readings`/`keyseq`. Requires `--lexicon-dir <dir>` pointing at a directory
with `latin-words.txt` and `latin-tech-seed.txt` (see `Source/Data/` and
`tools/lexicon/build_lexicon.py`) -- e.g. `--lexicon-dir Source/Data`.
Default is `off`, which reproduces this document's baseline byte-for-byte.

All three modes read one input per line from stdin and write one
tab-separated output line to stdout (no header row). Warnings about
out-of-scope input go to stderr and do not affect stdout's line count.

### `keys`

Input: one raw ASCII standard-layout key sequence per line -- the letters,
digits, and `,./;-` that the standard layout maps to Bopomofo components,
plus space and the tone keys `3`/`4`/`6`/`7`.

This mode simulates `Source/KeyHandler.mm`'s per-key order (see that file's
comments around line 460-560): for each key, `isValidKey` -> `combineKey`;
once a tone marker lands (or on a space, or at end of line, simulating a
trailing Enter), the pending reading is composed via `ReadingGrid::
insertReading` and, at the very end, `ReadingGrid::walk()` picks the best
path. It does **not** add any English-detection logic -- that gap is
exactly what F1 (see zhuyin-ime-personal.md) is meant to close, so this
harness can measure it honestly. Concretely: every ASCII letter is *also* a
valid standard-layout Bopomofo key, so typing an English word without
switching modes gets swallowed into the reading buffer and either silently
dropped (if the resulting "reading" matches no dictionary entry) or
misrecognized as unrelated Chinese character(s) -- essentially never left
as literal English text.

Output columns: `composed_text \t uncomposable_segments \t latency_us`
- `composed_text`: the final walked/composed string.
- `uncomposable_segments`: how many times a forced composition (tone key,
  space, or end of line) produced a reading with no dictionary match and
  was discarded. This is a weaker signal than "English survived" -- a
  discarded segment vanishes, but a *successful* but wrong Bopomofo match
  also does not count here even though it corrupted the output. Use the
  `keys` output's literal-text check (see `run_eval.py`) for that.
- `latency_us`: wall time for that one line's simulation (LM load excluded).

Example (from the acceptance check): `echo "su3cl3" | bopomix-eval --data <dir> --mode keys`
outputs `你好	0	<n>us` -- `su3` and `cl3` are two complete, tone-marked
syllables typed back to back with no space, each auto-composing the
instant its tone key lands.

### `readings`

Input: one space-separated Bopomofo reading sequence per line, e.g.
`ㄋㄧˇ ㄏㄠˇ`. Bypasses key handling and English entirely -- each reading
is inserted directly via `ReadingGrid::insertReading`, then `walk()` picks
the best path. This isolates the language model's homophone/candidate
ranking (F2) from the typing-simulation layer that `keys` mode covers.

Output columns: `composed_text \t insert_failures \t latency_us`
(`insert_failures` counts readings with no dictionary match, same idea as
`keys` mode's `uncomposable_segments`).

### `keyseq`

Input: one pure-CJK sentence per line (no English, no punctuation, no
digits -- see `build_corpus.py`'s `normalize()`). Used to generate corpus
ground truth, not to test the engine's typing/decoding behavior.

For each character run, greedily tries the longest substring (up to 8
characters, matching `ReadingGrid::kMaximumSpanLength`) that exists as an
exact dictionary value via `McBopomofoLM::getReading()`, which itself picks
the *highest-scoring* (most frequent) reading for that value -- the same
frequency data used for real candidate ranking, not a separate heuristic.
No keyboard map is reimplemented: the resulting syllables go through
`BopomofoKeyboardLayout::keySequenceFromSyllable()` to get standard-layout
keys.

Output columns: `readings \t standard_keys`
- `readings`: space-separated Bopomofo readings, one per character.
- `standard_keys`: space-separated per-syllable key sequences (see "Why a
  space after every syllable" below). A character with no dictionary entry
  at all emits the placeholder reading `_unknown_` and key `?` with a
  warning on stderr, rather than silently misaligning the two columns.

#### Why a space after every syllable

A tone-marked syllable (tone 2/3/4/5, i.e. any key press of `6`/`3`/`4`/`7`)
auto-composes the instant its tone key lands (see `keys` mode above), so no
separator is needed between it and the next syllable's keys -- that is
exactly the acceptance check's `su3cl3` case. But **tone 1 has no key
press** (`Formosa::Mandarin::BopomofoSyllable::Tone1 == 0`), so a tone-1
syllable only composes on a space or Enter; without one, the next
syllable's keys would merge into the still-open reading buffer via
`BopomofoReadingBuffer::combineKey`'s component-overwrite rules and corrupt
both syllables. `keyseq` mode sidesteps this by emitting a space after
*every* syllable's keys, tone-1 or not -- a space when the reading buffer
is already empty (tone-marked syllables clear it immediately) is a no-op in
`keys` mode's simulation, so this is always safe and never changes the
result for toned syllables while making tone-1 syllables round-trip
correctly.

**This is where the harness stops matching the real input method**, and it
matters when reading the `keys` column as if it were a recording of
someone typing. In the app, a space with an empty reading buffer is not a
no-op: it opens the candidate window (`Preferences.chooseCandidateUsingSpace`
is on by default). A person typing `dk3u3` never presses space between
those two syllables -- the tone key already composed the first one. So the
per-syllable delimiter spaces are an artifact of this file format, not
keystrokes, and the app-path measurement in `BASELINE.md` normalizes them
away (it drops a space that immediately follows a tone key, and keeps
every other one: tone-1 composition triggers and the separators that end
an English word). It reports the un-normalized numbers side by side so the
difference stays visible.

Two other divergences worth knowing about, both deliberate:

- A space that ends a rule-A Latin run *does* become a literal space here,
  matching `KeyHandler.mm`'s `_insertMixedScriptLiteralSpace`, so
  `acer api` composes as `acer api` in both.
- Everything else `KeyHandler` owns -- the candidate window, Esc,
  backspace, force-commit, the user override model -- has no counterpart
  here at all. Treat this tool as an engine regression check; the
  acceptance measurement lives in
  `BopomixTests/MixedScriptKeyHandlerTests.swift`
  (`testEval200ThroughKeyHandler`), which types the same corpus into a
  real `KeyHandler`.

## `build_corpus.py`

Builds the 200-row zh/en mixed-typing eval corpus from a **private,
out-of-repo** candidate file (see Privacy below).

```
python3 tools/eval/build_corpus.py \
    --cli ./build-engine/tools/eval/bopomix-eval \
    --data <ResourcesDir> \
    --candidates ~/Dev/mixime-private/corpus_candidates.txt \
    --output ~/Dev/mixime-private/eval200.tsv
```

Pipeline:
1. Read candidate lines, reject anything that looks like a list item,
   markdown heading, ID code, URL, or Slack mention, or that has no
   colloquial marker character at all (我/你/這/那/了/吧/嗎/可以/要/先/再/就
   -- a *weak* proxy: these are common function words in any register, not
   a real colloquial-vs-formal classifier, so this does not guarantee a
   casual tone, only rules out obviously structural/list content).
2. Normalize survivors to CJK ideographs + ASCII letters + single spaces
   only (strips punctuation, digits, and everything else) so every
   sentence maps cleanly onto the corpus's 2-way zh/en segment schema.
   This can occasionally leave a small grammatical gap where a stripped
   number used to sit (e.g. "您已至少 個月未使用" once had a number between
   至少 and 個月) -- acceptable for phonetic-segmentation testing, not
   meant to read as polished prose.
3. Re-check length (12-60 chars post-normalization), minimum CJK character
   count (>=6), and English token count (1-3 alphabetic runs of length
   2-15) on the normalized text, and dedupe.
4. Pad up to `--target` (default 200) with synthetic sentences generated
   from hand-written templates x a tech-term word list, tagged
   `source=synthetic`, if the vault candidates don't reach the target
   (they did not need to for this corpus -- see BASELINE.md).
5. Segment each sentence into ordered `{"text","lang":"zh"|"en"}` chunks.
6. Batch every zh segment across the whole corpus through one `bopomix-eval
   --mode keyseq` call to get its readings and standard-layout keys. A row
   with any character keyseq can't find a reading for is dropped (not kept
   with a placeholder), backfilled from the same candidate pool.
7. Writes the TSV (see Corpus format below) and, independently, a
   synthetic-only 10-row sample to `tools/eval/fixtures/sample10.tsv`
   (always regenerated fresh, regardless of whether the main corpus needed
   any synthetic padding).

Known limitation: the per-row English-token filter (step 3) requires runs
of length 2-15, but sentence segmentation (step 5) has no such floor, so a
stray single ASCII letter that survives normalization (e.g. a leftover
list-marker glyph like "O" or "V") can still show up as its own one-letter
`en` segment in a small number of rows. Not fixed in this pass; flagged for
follow-up rather than silently ignored.

### Corpus format (`eval200.tsv`)

Six tab-separated columns, no header:

```
id  sentence  segments(JSON)  readings  keys  source
```

- `id`: 1-based row number.
- `sentence`: the normalized (CJK + ASCII letters + spaces only) sentence.
- `segments`: JSON array of `{"text": "...", "lang": "zh"|"en"}`, in order.
- `readings`: each zh segment's space-separated Bopomofo readings, segments
  joined by `|` (e.g. `ㄋㄧˇ ㄏㄠˇ|ㄕˋ ㄐㄧㄝˋ`). For F2 scoring, join on `"
  "` instead of `|` to get one flat reading sequence for `bopomix-eval
  --mode readings` (a pipe is just this file's column-internal separator,
  not a real typing boundary).
- `keys`: every segment's standard-layout keys in order, space-separated
  (en segments are lowercased literal letters; zh segments come from
  `keyseq` mode, already space-separated per syllable). Feed this directly
  to `bopomix-eval --mode keys`. Note that the per-syllable spaces are a
  format artifact, not keystrokes -- see "Why a space after every
  syllable" above before feeding this column to anything that models the
  real key handling.
- `source`: `vault` (derived from Lman's own text, see Privacy) or
  `synthetic` (hand-written template, safe to publish).

## `run_eval.py`

Runs the two baseline metrics over a corpus TSV and writes `BASELINE.md`.

```
python3 tools/eval/run_eval.py \
    --corpus ~/Dev/mixime-private/eval200.tsv \
    --cli ./build-engine/tools/eval/bopomix-eval \
    --data <ResourcesDir>
```

- **F1** (English segment retention): types each row's `keys` column
  through `bopomix-eval --mode keys` and checks whether each gold English
  token still appears literally (case-insensitive substring) in the
  composed output. Expected near 0% today -- see `keys` mode's
  explanation above for why.
- **F2** (homophone/candidate-selection accuracy): concatenates each row's
  zh-segment readings (ignoring English and key-handling entirely) through
  `bopomix-eval --mode readings` and compares the composed text against the
  gold zh text, character by character.
- Per-sentence latency (avg/p50/p95/max) for both modes, taken from the
  CLI's own per-line timing (excludes process startup and LM load).

See `BASELINE.md` for the actual numbers, the exact command used to
generate them, and the date/data-file provenance.

Pass `--mixed on --lexicon-dir Source/Data` to measure P1 instead (see the
CLI's own `--mixed` doc above) -- this **appends** a "## P1" section to
`BASELINE.md` (via `--baseline-out`, default `BASELINE.md`) rather than
overwriting it, so the P0.5 baseline above stays intact for comparison.
Run with `--mixed off` (the default) first to (re)generate that baseline
section if it is ever missing or stale. The P1 section also lists the top
20 F1 failures by frequency, each re-run in isolation to categorize
whether the failure is context-dependent or a genuine rule/dictionary gap.

## Privacy

`~/Dev/mixime-private/` (candidates and the generated `eval200.tsv`) can
contain Lman's own text and must **never** enter this repo. The repo's
`.gitignore` has a blanket `*.private.*` rule as a backstop, and
`tools/eval/fixtures/sample10.tsv` (10 synthetic-only rows, regenerated by
`build_corpus.py`) is the only corpus-shaped file meant to be committed
here. Do not add a `--output` pointing inside this repo.
