# mixime P0.5 baseline

Generated: 2026-09-10T00:02:00+08:00

Engine: mixime (fork of McBopomofo, upstream commit f5ba010 at fork time),
unmodified F1/F2 logic -- this is the *baseline*, i.e. what the stock
McBopomofo engine does today, before any zh/en mixed-typing or AI
re-ranking work lands.

Corpus: `/Users/lman/Dev/mixime-private/eval200.tsv` -- 200 rows (vault=200, synthetic=0).
Language model data: `/Users/lman/Dev/McBopomofo/build/Build/Products/Debug/McBopomofo.app/Contents/Resources/data.txt` (sha256 0deae7b7c1dcde1d7a30d139e7068543e0c0e7112e944b63eb52947bca1db7ac).

## Commands

```
cmake -S Source/Engine -B build-engine -DENABLE_TEST=ON
cmake --build build-engine
python3 tools/eval/run_eval.py --corpus /Users/lman/Dev/mixime-private/eval200.tsv \
    --cli build-engine/tools/eval/mixime-eval --data /Users/lman/Dev/McBopomofo/build/Build/Products/Debug/McBopomofo.app/Contents/Resources
```

## Results

### F1 -- English segment retention (mode `keys`)

Types each corpus row's full ASCII key sequence (Chinese Bopomofo keys and
English letters interleaved exactly as they would be typed, with no mode
switch) through the real KeyHandler-equivalent FSM, then checks whether
each gold English token still appears literally in the composed output.

| metric | value |
|---|---|
| token-level retention | 0/385 = 0.0% |
| row-level (all English tokens in row retained) | 0/200 = 0.0% |
| latency (avg / p50 / p95 / max) | 2462us / 2520us / 4155us / 6043us |

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
| char-level accuracy | 4369/4586 = 95.3% |
| rows with a length mismatch | 1/200 |
| latency (avg / p50 / p95 / max) | 2190us / 2230us / 3845us / 5604us |

This number is the unmodified ReadingGrid Viterbi walk's accuracy against
the corpus's gold characters -- i.e. how good the stock language model's
candidate ranking already is, independent of typing/segmentation. Any F2
regression after a future change (e.g. AI re-ranking in P2) should be
compared against this number.


## P1 -- F1 zh/en mixed typing, rule-based pass (2026-09-09)

Generated: 2026-09-10T00:02:02+08:00

Same corpus and language model as the P0.5 baseline above, run with
`--mixed on` (Source/Engine/MixedScript/, see
~/.claude/plans/zhuyin-ime-personal.md's P1 design section) instead of the
baseline's unmodified engine.

### Commands

```
python3 tools/eval/run_eval.py --corpus /Users/lman/Dev/mixime-private/eval200.tsv \
    --cli build-engine/tools/eval/mixime-eval --data /Users/lman/Dev/McBopomofo/build/Build/Products/Debug/McBopomofo.app/Contents/Resources \
    --mixed on --lexicon-dir Source/Data
```

### F1 -- English segment retention (mode `keys`, mixed=on)

| metric | value |
|---|---|
| token-level retention | 368/385 = 95.6% |
| row-level (all English tokens in row retained) | 185/200 = 92.5% |
| latency (avg / p50 / p95 / max) | 2637us / 2694us / 4622us / 6609us |

### F2 -- homophone/candidate-selection accuracy (mode `readings`, mixed=on)

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
| latency (avg / p50 / p95 / max) | 2207us / 2247us / 3941us / 5464us |

### F1 failures, top 12 by frequency, categorized

Categorization method: each distinct failed token is re-run *alone* (with
the same trailing space every corpus row's `keys` column already puts
after an English segment). If it survives alone, the failure is
context-dependent (something about the surrounding sentence, not the word
itself); if it still fails alone, either the shape/dictionary rules
genuinely do not cover it, or there is a bug -- see the category column.

| token | count (out of 385 total tokens) | category |
|---|---|---|
| b | 3 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| x | 3 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| i | 2 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| v | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| c | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| p | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| m | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| e | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| d | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| mm | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| h | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |
| zz | 1 | 規則錯判／未命中詞典（獨立測試也失敗，需人工檢視） |

