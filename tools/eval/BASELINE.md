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

## P1 round 2 -- app path (real KeyHandler), 2026-09-10

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
| latency per row (avg / p50 / p95 / max) | 5300us / 5394us / 9382us / 13339us | 6899us / 6868us / 12314us / 17498us |

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
| latency per row (avg / p50 / p95 / max) | 4931us / 4992us / 8906us / 12641us | 4872us / 4994us / 8852us / 12516us |

Note that the "zh accuracy within the mixed sentence" row in the
first table is *not* comparable to 95.3%: it is measured on
text typed from keys with English words interleaved, where an
English run legitimately breaks the phrase context around it,
and its own no-mixed-typing counterpart is 56.2%. The
pure-Chinese control above is the like-for-like number.
