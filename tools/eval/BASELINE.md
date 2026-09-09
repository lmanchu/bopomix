# mixime P0.5 baseline

Generated: 2026-09-09T08:18:36+08:00

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
| latency (avg / p50 / p95 / max) | 2511us / 2563us / 4395us / 6222us |

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
| latency (avg / p50 / p95 / max) | 2224us / 2251us / 3840us / 5660us |

This number is the unmodified ReadingGrid Viterbi walk's accuracy against
the corpus's gold characters -- i.e. how good the stock language model's
candidate ranking already is, independent of typing/segmentation. Any F2
regression after a future change (e.g. AI re-ranking in P2) should be
compared against this number.
