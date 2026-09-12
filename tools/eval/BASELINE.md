# mixime P0.5 baseline

Generated: 2026-09-10T17:21:33+08:00

Engine: mixime (fork of McBopomofo, upstream commit f5ba010 at fork time),
unmodified F1/F2 logic -- this is the *baseline*, i.e. what the stock
McBopomofo engine does today, before any zh/en mixed-typing or AI
re-ranking work lands.

Corpus: `/Users/lman/Dev/mixime-private/eval200.tsv` -- 200 rows (vault=200, synthetic=0).
Language model data: `build/Build/Products/Debug/McBopomofo.app/Contents/Resources/data.txt` (sha256 0deae7b7c1dcde1d7a30d139e7068543e0c0e7112e944b63eb52947bca1db7ac).

## Commands

```
cmake -S Source/Engine -B build-engine -DENABLE_TEST=ON
cmake --build build-engine
python3 tools/eval/run_eval.py --corpus /Users/lman/Dev/mixime-private/eval200.tsv \
    --cli build-engine/tools/eval/mixime-eval --data build/Build/Products/Debug/McBopomofo.app/Contents/Resources
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
| token-level retention | 0/385 = 0.0% |
| row-level (all English tokens in row retained) | 0/200 = 0.0% |
| latency (avg / p50 / p95 / max) | 2475us / 2517us / 4308us / 6012us |

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
| char-level accuracy | 4369/4586 = 95.3% |
| rows with a length mismatch | 1/200 |
| latency (avg / p50 / p95 / max) | 2194us / 2218us / 3852us / 5579us |

This number is the unmodified ReadingGrid Viterbi walk's accuracy against
the corpus's gold characters -- i.e. how good the stock language model's
candidate ranking already is, independent of typing/segmentation. Any F2
regression after a future change (e.g. AI re-ranking in P2) should be
compared against this number.


## P1 -- engine-only (no KeyHandler; engine regression only)

Generated: 2026-09-10T17:21:35+08:00

Same corpus and language model as the P0.5 baseline above, run with
`--mixed on` (Source/Engine/MixedScript/, see
~/.claude/plans/zhuyin-ime-personal.md's P1 design section) instead of the
baseline's unmodified engine.

**These numbers are not acceptance criteria.** `mixime-eval` reimplements
the *ordering* of KeyHandler.mm's operations over the same engine; it has
no candidate window, no Esc/backspace handling, no force-commit and no
user override model, so it cannot see the class of defect that made the
first P1 round unshippable. The acceptance measurement is the app-path
section at the end of this file, produced by
`MixedScriptKeyHandlerTests.testEval200ThroughKeyHandler`. Keep this
section as an engine regression check only.

### Commands

```
python3 tools/eval/run_eval.py --corpus /Users/lman/Dev/mixime-private/eval200.tsv \
    --cli build-engine/tools/eval/mixime-eval --data build/Build/Products/Debug/McBopomofo.app/Contents/Resources \
    --mixed on --lexicon-dir Source/Data
```

### F1 -- English segment retention (mode `keys`, mixed=on, engine-only)

| metric | value |
|---|---|
| token-level retention | 349/385 = 90.6% |
| row-level (all English tokens in row retained) | 167/200 = 83.5% |
| latency (avg / p50 / p95 / max) | 2571us / 2623us / 4451us / 6213us |

### F2 -- homophone/candidate-selection accuracy (mode `readings`, mixed=on, engine-only)

Expected to be unchanged from the P0.5 baseline above -- rule B only adds a
low-scored alternate candidate at an existing reading's node (see
LatinPassthroughLM), it never changes what the *Chinese* candidate for a
reading is or its score, and `readings` mode never touches
BopomofoReadingBuffer/MixedScriptTracker in the first place (see
tools/eval/README.md's mode description) -- only `keys` mode does.

| metric | value |
|---|---|
| char-level accuracy | 4369/4586 = 95.3% |
| rows with a length mismatch | 1/200 |
| latency (avg / p50 / p95 / max) | 2207us / 2224us / 3846us / 5597us |

### F1 failures, top 16 by frequency, categorized

Categorization method: each distinct failed token is re-run *alone* (with
the same trailing space every corpus row's `keys` column already puts
after an English segment). If it survives alone, the failure is
context-dependent (something about the surrounding sentence, not the word
itself); if it still fails alone, either the shape/dictionary rules
genuinely do not cover it, or there is a bug -- see the category column.

| token | count (out of 385 total tokens) | category |
|---|---|---|
| ai | 10 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| app | 6 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| b | 3 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| x | 3 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| i | 2 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| ui | 2 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| v | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| c | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| p | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| no | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| m | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| e | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| d | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| mm | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| h | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| zz | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |

## P1 round 2 -- app path (real KeyHandler), 2026-09-12

Produced by `MixedScriptKeyHandlerTests.testEval200ThroughKeyHandler`
(`xcodebuild -scheme McBopomofo test`), typing each corpus row's
`keys` column into a real `KeyHandler` -- candidate states, Esc,
Enter, the user override model and all -- and reading the
committed text back. **This is the acceptance number.** The
`mixime-eval` sections above it measure the engine only.

Two key sequences are reported. `build_corpus.py` puts a
delimiter space after every syllable, including ones a tone
digit already finished; nobody types those, and in a real input
method a space after a finished syllable means "show
candidates". "human-typed" drops exactly those spaces (a space
immediately after a 3/4/6/7 tone key) and keeps every other
one -- tone-1 composition triggers and the separators that end
an English word. "raw" is the corpus column verbatim, kept
visible so the difference is not hidden.

| metric | human-typed keys | raw corpus keys |
|---|---|---|
| **F1 token retention** | **349/385 = 90.6%** | 335/385 = 87.0% |
| F1 row-level (all tokens kept) | 167/200 = 83.5% | 160/200 = 80.0% |
| zh accuracy within the mixed sentence | 3901/4586 = 85.1% | 1845/4586 = 40.2% |
| rows with a zh length mismatch | 37/200 | 146/200 |
| latency per row (avg / p50 / p95 / max) | 6337us / 6355us / 10667us / 14810us | 8172us / 8077us / 14387us / 19236us |

### Pure-Chinese control: does turning this on damage normal typing?

The same rows with their English segments removed, so the input
is nothing but ordinary Bopomofo. This is the comparison the
95.3% P0.5 baseline is actually about, and the one the first
round failed (it dropped pure-Chinese accuracy by 5.1 points
while the harness's own F2 number stayed flat, because F2's
`readings` mode never runs the key handling at all).

| metric | mixedScriptEnabled = **on** | mixedScriptEnabled = off |
|---|---|---|
| **zh character accuracy** | **4369/4586 = 95.3%** | 4369/4586 = 95.3% |
| rows with a zh length mismatch | 1/200 | 1/200 |
| latency per row (avg / p50 / p95 / max) | 5218us / 5268us / 9302us / 13439us | 4990us / 5035us / 9148us / 12692us |

Note that the "zh accuracy within the mixed sentence" row in the
first table is *not* comparable to 95.3%: it is measured on
text typed from keys with English words interleaved, where an
English run legitimately breaks the phrase context around it,
and its own no-mixed-typing counterpart is 56.2%. The
pure-Chinese control above is the like-for-like number.

## P3 -- English prediction + Tab completion, 2026-09-12

Produced by `LatinCompletionKeyHandlerTests.testEval200LatinCompletion`
(`xcodebuild -scheme McBopomofo test`). For every eval200 English
token of length >= 3, simulates typing it letter by letter into
a real `KeyHandler` and records the first prefix length at which
the completion tooltip's top-1 prediction equals the token --
i.e. how many letters the user would have typed before the
input method offered the rest.

This measures what the user is *shown*. Since P3 round 4 the
tooltip needs a run of `kMinLatinRunLengthForPredictionTooltip`
(4) letters before it appears, so the "within 2 letters" and
"within 3 letters" rows below are necessarily 0 -- they are
kept only so the table still lines up with the two earlier
runs. Tab and Shift+Tab still complete a two-letter run on
demand; what changed is that the input method no longer
volunteers a guess that early. The reason is in
docs/REVERIFY-P3-2026-09-12.md: over 100 keystrokes of 17
words the reviewer types daily, the old floor of 2 put a wrong
word on screen 33 times to save 7 keystrokes.

Two passes: "no history" evaluates every token cold; "with
history" replays the corpus in row order and, after evaluating
each row, *types and commits* its eligible tokens, which is
the only way production learns anything (KeyHandler's
_commitMixedScriptLatinRun -> _learnTypedLatinWordIfEligible).
Two commits of the same string are what confirm a word, so a
token's third occurrence is the first that can benefit. Round
3 instead called `acceptLatinCompletion(value:)`, which
confirms a word in one call -- its 48.8% was an optimistic
upper bound, not the production rule the prose claimed
(docs/REVERIFY-P3-2026-09-12.md's P-4).

"never completable" tokens are split by asking, in this order:
**Rule A never triggered** (the letters never stopped being a
legal Bopomofo shape, so the run never became Latin and no
completion surface was reachable at all -- `app` is `ㄇㄣ`,
`coo` is `ㄏㄟ`; a P1 coverage limit that no amount of
frequency data can move), **below the tooltip floor** (pressing
Tab or Shift+Tab at two or three letters *would* have completed
the token; the ranking found it and the display policy declined
to volunteer it), **ranking miss** (the lowercase form is a
dictionary word that never ranked top-1 at any tested prefix --
a different, better-ranked word owns every prefix),
**inflected form** (a suffix-stripped lemma guess is a
dictionary word but the exact form typed is not -- P3 fix #1's
SCOWL-sourced word list, which includes inflected forms
directly, keeps this near 0), and **not in the dictionary** (a
genuine vocabulary gap: a name, an acronym, a product).

Those first two categories are corrections. Round 2's
version short-circuited on "does the token contain an
uppercase letter", filing 61 tokens (`API`, `App`, `Apple`,
`Blog`, `CLI`, `Games`, `Meet`, `Steam`, `Story`, `This`,
`Tool`) as vocabulary gaps when their lowercase forms are
ordinary dictionary entries; asking the dictionary first fixed
that, but left a second error in place -- a token whose run
never locked was counted as a ranking miss purely because its
lowercase form is in the dictionary, which is how "62% of
never-completable tokens are ranking misses" was arrived at.
The tooltip floor would have created a third version of the
same mistake, so it gets its own row too. Each points at
different work: a ranking miss wants a real frequency source,
a Rule-A failure wants better Rule-A coverage, a floor
casualty wants a better way to surface a completion the
ranking already has, and a missing word wants a bigger
dictionary.

What the two changes cost, stated plainly: average keystrokes
saved per token went from 0.76 to 0.39 with no history and from
0.94 to 0.46 with it. Roughly half of that is the tooltip
floor (the "below the tooltip floor" row is the population that
moved) and the rest is "with history" no longer confirming
every token on its first sighting. Both are measurements of a
deliberately more conservative product, not regressions to
chase back.

### No history

| metric | value |
|---|---|
| completable within 2 letters | 0/330 = 0.0% |
| completable within 3 letters | 0/330 = 0.0% |
| completable within 4 letters | 76/330 = 23.0% |
| completable within 5 letters | 123/330 = 37.3% |
| completable within 6 letters | 134/330 = 40.6% |
| never completable | 187/330 = 56.7% |
|  - Rule A never triggered (the run never became Latin at all) | 18 |
|  - below the tooltip floor (Tab would have completed it, the tooltip never offered) | 32 |
|  - ranking miss (in the dictionary, never ranked top-1 at any tested prefix) | 81 |
|  - inflected form (lemma in the dictionary, inflected form is not) | 1 |
|  - not in the dictionary (name, acronym, product) | 55 |
| average keystrokes saved per token (letters skipped minus the Tab press, 0 for non-completable) | 0.39 |

### With history (production learning replayed between rows)

| metric | value |
|---|---|
| completable within 2 letters | 0/330 = 0.0% |
| completable within 3 letters | 0/330 = 0.0% |
| completable within 4 letters | 95/330 = 28.8% |
| completable within 5 letters | 127/330 = 38.5% |
| completable within 6 letters | 138/330 = 41.8% |
| never completable | 184/330 = 55.8% |
|  - Rule A never triggered (the run never became Latin at all) | 18 |
|  - below the tooltip floor (Tab would have completed it, the tooltip never offered) | 35 |
|  - ranking miss (in the dictionary, never ranked top-1 at any tested prefix) | 82 |
|  - inflected form (lemma in the dictionary, inflected form is not) | 1 |
|  - not in the dictionary (name, acronym, product) | 48 |
| average keystrokes saved per token (letters skipped minus the Tab press, 0 for non-completable) | 0.46 |

### Pure-Chinese control: ON vs OFF, character by character

Same idea as testEval200ThroughKeyHandler's pure-Chinese control,
but toggling `latinCompletionEnabled` (mixedScriptEnabled stays
on in both runs) instead of `mixedScriptEnabled` itself, and only
typing each row's Chinese-segment keys.

| metric | value |
|---|---|
| rows with any character difference | 0/200 |
| matching characters | 4584/4584 = 100.0% |
