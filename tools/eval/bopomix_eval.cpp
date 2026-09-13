// Copyright (c) 2026 and onwards The Bopomix Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//
// bopomix-eval: a headless CLI harness for the McBopomofo/bopomix C++ engine.
//
// This tool exists so that eval scripts (see tools/eval/run_eval.py) can
// drive the *real* engine (Mandarin::BopomofoReadingBuffer +
// Gramambular2::ReadingGrid + McBopomofoLM) without an actual macOS input
// method process. It intentionally re-implements only the *ordering* of
// operations found in Source/KeyHandler.mm (isValidKey -> combineKey ->
// composeReading -> insertReading -> walk), not the engine logic itself, so
// that results reflect the shipping engine's actual behavior (including its
// current lack of English-awareness), not a re-guess of it.

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "Mandarin/Mandarin.h"
#include "McBopomofoLM.h"
#include "MixedScript/latin_lexicon.h"
#include "MixedScript/latin_passthrough_lm.h"
#include "MixedScript/mixed_script_tracker.h"
#include "UTF8Helper.h"
#include "gramambular2/reading_grid.h"

namespace {

using Formosa::Gramambular2::ReadingGrid;
using Formosa::Mandarin::BopomofoKeyboardLayout;
using Formosa::Mandarin::BopomofoReadingBuffer;
using Formosa::Mandarin::BopomofoSyllable;
using McBopomofo::McBopomofoLM;
using McBopomofo::MixedScript::LatinLexicon;
using McBopomofo::MixedScript::MixedScriptTracker;
using McBopomofo::MixedScript::Verdict;

struct Args {
  std::filesystem::path dataDir;
  std::filesystem::path lexiconDir;
  std::string layout = "standard";
  std::string mode;
  bool mixed = false;
};

void PrintUsage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0
      << " --data <ResourcesDir> --mode {keys|readings|keyseq} "
         "[--layout standard] [--mixed on|off] [--lexicon-dir <dir>]\n"
      << "\n"
      << "Modes:\n"
      << "  keys      stdin: one ASCII standard-layout key sequence per "
         "line (letters/digits/,./;- plus space).\n"
      << "            stdout (tab-separated): composed_text\\t"
         "uncomposable_segments\\tlatency_us\n"
      << "  readings  stdin: one space-separated Bopomofo reading sequence "
         "per line (e.g. \"ㄋㄧˇ ㄏㄠˇ\").\n"
      << "            stdout (tab-separated): composed_text\\t"
         "insert_failures\\tlatency_us\n"
      << "  keyseq    stdin: one pure-CJK sentence per line.\n"
      << "            stdout (tab-separated): readings\\tstandard_keys\n"
      << "\n"
      << "--mixed on drives `keys` mode through the same "
         "Source/Engine/MixedScript/ decision engine KeyHandler.mm uses "
         "(see zhuyin-ime-personal.md's P1 section); it is a no-op for "
         "readings/keyseq. --mixed on requires --lexicon-dir <dir> "
         "containing latin-words.txt and latin-tech-seed.txt (see "
         "tools/lexicon/build_lexicon.py and Source/Data/).\n";
}

bool ParseArgs(int argc, char** argv, Args* outArgs, std::string* error) {
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--data" && i + 1 < argc) {
      outArgs->dataDir = argv[++i];
    } else if (arg == "--lexicon-dir" && i + 1 < argc) {
      outArgs->lexiconDir = argv[++i];
    } else if (arg == "--layout" && i + 1 < argc) {
      outArgs->layout = argv[++i];
    } else if (arg == "--mode" && i + 1 < argc) {
      outArgs->mode = argv[++i];
    } else if (arg == "--mixed" && i + 1 < argc) {
      std::string value = argv[++i];
      if (value == "on") {
        outArgs->mixed = true;
      } else if (value == "off") {
        outArgs->mixed = false;
      } else {
        *error = "--mixed must be 'on' or 'off', got: " + value;
        return false;
      }
    } else if (arg == "--help" || arg == "-h") {
      return false;
    } else {
      *error = "unrecognized or incomplete argument: " + arg;
      return false;
    }
  }
  if (outArgs->mixed && outArgs->lexiconDir.empty()) {
    *error = "--mixed on requires --lexicon-dir <dir>";
    return false;
  }
  if (outArgs->dataDir.empty()) {
    *error = "--data <ResourcesDir> is required";
    return false;
  }
  if (outArgs->mode != "keys" && outArgs->mode != "readings" &&
      outArgs->mode != "keyseq") {
    *error = "--mode must be one of: keys, readings, keyseq";
    return false;
  }
  if (outArgs->layout != "standard") {
    // Only the standard (dayi... actually "Da Chien"/Standard) layout is
    // supported for now. See zhuyin-ime-personal.md P0.5 scope.
    *error = "only --layout standard is supported by this eval harness";
    return false;
  }
  return true;
}

// Strips a trailing '\r' so the tool tolerates CRLF-terminated corpus files.
std::string StripCR(std::string line) {
  if (!line.empty() && line.back() == '\r') {
    line.pop_back();
  }
  return line;
}

std::string JoinValues(const ReadingGrid::WalkResult& walk) {
  std::string text;
  for (const std::string& value : walk.valuesAsStrings()) {
    text += value;
  }
  return text;
}

// Simulates KeyHandler.mm's per-key handling order for the standard layout:
//   isValidKey -> combineKey -> (if toned) composeReading -> insertReading
// A space (or end of line, simulating a trailing Enter) also forces
// composition of whatever is pending in the reading buffer, matching
// KeyHandler.mm:516 ("composeReading |= (!empty && (space || enter))").
//
// Characters that are valid standard-layout BPMF keys but never combine into
// a reading recognized by the language model (e.g. most English letter runs)
// are silently dropped after the forced flush, exactly as KeyHandler.mm's
// errorCallback path does (Preferences.keepReadingUponCompositionError is
// off by default) -- unless `lexicon` is non-null (--mixed on), in which
// case this drives the same Source/Engine/MixedScript/ decision engine
// KeyHandler.mm's mixedScript hookup uses, mirroring its ordering exactly
// (see the inline comments below and KeyHandler.mm's own "P1 zh/en mixed
// typing" sections) so results reflect the shipping app's behavior. With
// `lexicon == nullptr` this function's behavior is byte-for-byte identical
// to before P1.
int RunKeysMode(const std::shared_ptr<McBopomofoLM>& lm,
                const BopomofoKeyboardLayout* layout,
                const LatinLexicon* lexicon) {
  static const std::string kMixedScriptLatinKey = "_latin_";

  std::string line;
  while (std::getline(std::cin, line)) {
    line = StripCR(line);

    const auto start = std::chrono::steady_clock::now();

    ReadingGrid grid(lm);
    BopomofoReadingBuffer buffer(layout);
    int uncomposable = 0;
    MixedScriptTracker tracker(lexicon);  // Unused when lexicon == nullptr.

    // Mirrors KeyHandler.mm's _commitMixedScriptLatinRun: inserts the
    // pending run's literal text as a single node via a fixed synthetic
    // reading in the same LatinPassthroughLM McBopomofoLM's unigram
    // dispatch merges in (see McBopomofoLM::setMixedScriptEnabled()).
    auto commitLatinText = [&](const std::string& text) {
      if (text.empty()) {
        return;
      }
      lm->mixedScriptLM().registerSoleEntry(kMixedScriptLatinKey, text);
      if (!grid.insertReading(kMixedScriptLatinKey)) {
        ++uncomposable;  // Shouldn't happen; stay honest if it somehow does.
      }
      lm->mixedScriptLM().clearKey(kMixedScriptLatinKey);
    };

    auto commitLatinRun = [&]() {
      std::string word = tracker.latinRun();
      tracker.reset();
      commitLatinText(word);
    };

    // `isSpaceKey` is true only for an actual space keystroke (not
    // end-of-line), which is what decides whether a literal space follows
    // the run -- mirroring KeyHandler.mm's _insertMixedScriptLiteralSpace.
    auto flush = [&](bool isSpaceOrEnd, bool isSpaceKey) {
      if (buffer.isEmpty()) {
        return;
      }
      std::string reading = buffer.syllable().composedString();

      if (lexicon != nullptr && tracker.hasPendingRun() &&
          !lm->hasUnigrams(reading)) {
        // Rule A safety net (see KeyHandler.mm's identical fallback next
        // to its own hasUnigrams() check): BopomofoShapeTracker's
        // structural check does not catch every case -- a run can keep a
        // live shape the whole time and still land on a reading with no
        // dictionary entry at all.
        buffer.clear();
        commitLatinRun();
        if (isSpaceKey) {
          commitLatinText(" ");
        }
        return;
      }

      // Rule B: a dictionary word with a still-live shape registers a
      // Latin alternate at this exact reading *before* insertReading()
      // below, since ReadingGrid caches a node's unigrams immutably the
      // instant it is created (see LatinPassthroughLM's class doc). The
      // score mirrors KeyHandler.mm's: just under the reading's best
      // existing unigram, so the English form is the candidate window's
      // second row without changing what the walk picks.
      bool mixedScriptAmbiguous =
          lexicon != nullptr && !tracker.isLatinLocked() &&
          tracker.onBoundary(/*isSpaceOrEnd=*/false) == Verdict::kAmbiguous;
      std::string mixedScriptWord = tracker.latinRun();
      if (mixedScriptAmbiguous) {
        double topScore = std::numeric_limits<double>::lowest();
        for (const auto& unigram : lm->getUnigrams(reading)) {
          topScore = std::max(topScore, unigram.score());
        }
        lm->mixedScriptLM().registerAlternate(
            reading, mixedScriptWord,
            McBopomofo::MixedScript::LatinPassthroughLM::ScoreJustBelow(
                topScore));
      }

      if (!grid.insertReading(reading)) {
        ++uncomposable;
      } else if (mixedScriptAmbiguous) {
        // A trailing space/end-of-line commits the run as English only
        // for words in the user's own lexicon (see
        // MixedScriptTracker::onBoundary()); this harness never loads
        // one, so in practice this never fires here.
        if (tracker.onBoundary(isSpaceOrEnd) == Verdict::kLatin) {
          size_t loc = grid.cursor() - 1;
          ReadingGrid::Candidate latinCandidate(reading, mixedScriptWord);
          grid.overrideCandidate(
              loc, latinCandidate,
              ReadingGrid::Node::OverrideType::kOverrideValueWithHighScore);
        }
      }
      if (mixedScriptAmbiguous) {
        lm->mixedScriptLM().clearKey(reading);
      }
      if (lexicon != nullptr) {
        tracker.reset();
      }
      buffer.clear();
    };

    for (char rawKey : line) {
      // P1 zh/en mixed typing hook -- must run *before* the space/valid-key
      // dispatch below, exactly like KeyHandler.mm's placement at the top
      // of handleInput: (its own hook runs before even the space-handling
      // code further down that function). Running it after the space
      // check instead would miss the far more common case of a Rule-A run
      // ending in a space rather than a tone digit/punctuation, since
      // space would `continue` before ever reaching this.
      bool isAsciiLetterKey = rawKey >= 'a' && rawKey <= 'z';
      if (lexicon != nullptr && isAsciiLetterKey && buffer.isValidKey(rawKey)) {
        Verdict verdict = tracker.feedKey(layout, rawKey);
        if (verdict == Verdict::kLatin) {
          // Rule A (or already locked): stop feeding the real reading
          // buffer for the rest of this run -- never silently drop the
          // key, the literal text lives in tracker.latinRun() until the
          // next boundary commits it (see commitLatinRun()).
          buffer.clear();
          continue;
        }
        // kChinese/kAmbiguous: fall through, the tracker is only
        // observing so far -- the real buffer still owns composition.
      } else if (lexicon != nullptr && tracker.isLatinLocked()) {
        // Any key that did not continue the run above (including space)
        // ends a Rule-A-locked run: commit it now, before this key gets
        // its own handling below (this harness never sees backspace/Esc,
        // unlike KeyHandler.mm, so no exclusion is needed for those here).
        commitLatinRun();
        if (rawKey == ' ') {
          // The space that ended the run is a word separator, not a
          // tone-1 trigger (there is no pending reading) -- KeyHandler.mm
          // puts a literal space node in the grid here, so this does too.
          commitLatinText(" ");
          continue;
        }
      }

      if (rawKey == ' ') {
        // KeyHandler.mm - space forces composition of a pending
        // (typically tone-1, unmarked) reading. A space with an empty
        // buffer is not a printable character in McBopomofo's default
        // bindings (chooseCandidateUsingSpace is on by default, so it
        // opens the candidate window instead of committing a literal
        // space); this harness has no candidate UI, so it is a no-op
        // then. Only a space that ends a *Latin* run becomes a literal
        // space, which is handled above and inside flush().
        flush(/*isSpaceOrEnd=*/true, /*isSpaceKey=*/true);
        continue;
      }

      if (buffer.isValidKey(rawKey)) {
        buffer.combineKey(rawKey);
        if (buffer.hasToneMarker() && !buffer.hasToneMarkerOnly()) {
          // KeyHandler.mm - a tone key (with a consonant/vowel already
          // present) immediately triggers composition, no space needed.
          flush(/*isSpaceOrEnd=*/false, /*isSpaceKey=*/false);
        }
        continue;
      }
      // A key outside the standard layout's BPMF map. Out of scope for the
      // "keys" mode per the eval harness spec (which only feeds
      // letters/digits/,./;-/space), but handled defensively: flush any
      // pending reading (mirrors the key not being consumed by the reading
      // buffer and falling through in KeyHandler.mm) and skip the key.
      flush(/*isSpaceOrEnd=*/false, /*isSpaceKey=*/false);
      std::cerr << "bopomix-eval: warning: key '" << rawKey
                << "' is not a standard-layout BPMF key; skipped\n";
    }
    // Simulate a trailing Enter/commit at end of line -- exactly like any
    // other non-continuing key mid-line (see the loop above), this must
    // first commit a still-pending Rule-A-locked run, since flush() below
    // only knows about _bpmfReadingBuffer, not about the tracker (this
    // matters whenever the corpus's last segment on a line is English and
    // rule A fires without a following space, e.g. "sow" as the final
    // token of a row -- build_corpus.py's " ".join(keys_parts) puts no
    // trailing space after the very last segment).
    if (lexicon != nullptr && tracker.isLatinLocked()) {
      commitLatinRun();
    }
    flush(/*isSpaceOrEnd=*/true, /*isSpaceKey=*/false);

    const ReadingGrid::WalkResult walk = grid.walk();
    const std::string text = JoinValues(walk);

    const auto elapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
                                std::chrono::steady_clock::now() - start)
                                .count();

    std::cout << text << '\t' << uncomposable << '\t' << elapsedUs << '\n';
  }
  return 0;
}

// Mode "readings": bypasses key mechanics entirely and inserts each
// space-separated Bopomofo reading directly, for measuring the language
// model's homophone-selection accuracy (F2) independent of key handling.
int RunReadingsMode(const std::shared_ptr<McBopomofoLM>& lm) {
  std::string line;
  while (std::getline(std::cin, line)) {
    line = StripCR(line);

    const auto start = std::chrono::steady_clock::now();

    ReadingGrid grid(lm);
    int insertFailures = 0;

    std::istringstream iss(line);
    std::string reading;
    while (iss >> reading) {
      if (!grid.insertReading(reading)) {
        ++insertFailures;
      }
    }

    const ReadingGrid::WalkResult walk = grid.walk();
    const std::string text = JoinValues(walk);

    const auto elapsedUs = std::chrono::duration_cast<std::chrono::microseconds>(
                                std::chrono::steady_clock::now() - start)
                                .count();

    std::cout << text << '\t' << insertFailures << '\t' << elapsedUs << '\n';
  }
  return 0;
}

// Mode "keyseq": greedy longest-match segmentation of a pure-CJK sentence
// using McBopomofoLM::getReading(), which itself picks the highest-scoring
// (most frequent) reading for an exact dictionary value -- this is the same
// frequency data the production candidate ranking uses, so this is not a
// separately-invented heuristic. keySequenceFromSyllable() (from
// Mandarin.h) is used to turn each resulting syllable back into standard
// layout keys, so no keyboard map is reimplemented here.
int RunKeyseqMode(const std::shared_ptr<McBopomofoLM>& lm,
                  const BopomofoKeyboardLayout* layout) {
  constexpr int kMaxSpan = 8;  // matches ReadingGrid::kMaximumSpanLength

  std::string line;
  while (std::getline(std::cin, line)) {
    line = StripCR(line);
    if (line.empty()) {
      std::cout << "\t\n";
      continue;
    }

    const std::vector<std::string> chars = McBopomofo::Split(line);
    std::vector<std::string> readings;
    std::string keys;

    size_t i = 0;
    while (i < chars.size()) {
      const int maxLen =
          static_cast<int>(std::min<size_t>(kMaxSpan, chars.size() - i));
      bool matched = false;
      for (int len = maxLen; len >= 1; --len) {
        std::string phrase;
        for (int k = 0; k < len; ++k) {
          phrase += chars[i + static_cast<size_t>(k)];
        }
        const std::string reading = lm->getReading(phrase);
        if (reading.empty()) {
          continue;
        }
        // `reading` is one or more syllables joined by '-', one per
        // character in `phrase`, in order (see data.txt's format).
        std::istringstream rs(reading);
        std::string syllableStr;
        while (std::getline(rs, syllableStr, '-')) {
          readings.push_back(syllableStr);
          const BopomofoSyllable syllable =
              BopomofoSyllable::FromComposedString(syllableStr);
          keys += layout->keySequenceFromSyllable(syllable);
          keys += ' ';
        }
        i += static_cast<size_t>(len);
        matched = true;
        break;
      }
      if (!matched) {
        std::cerr << "bopomix-eval: warning: no dictionary reading for "
                     "character '"
                  << chars[i] << "' in keyseq mode; emitting placeholder\n";
        readings.push_back("_unknown_");
        keys += "?";
        keys += ' ';
        ++i;
      }
    }

    if (!keys.empty() && keys.back() == ' ') {
      keys.pop_back();
    }

    std::string readingsStr;
    for (size_t idx = 0; idx < readings.size(); ++idx) {
      if (idx) {
        readingsStr += ' ';
      }
      readingsStr += readings[idx];
    }

    std::cout << readingsStr << '\t' << keys << '\n';
  }
  return 0;
}

}  // namespace

int main(int argc, char** argv) {
  Args args;
  std::string error;
  if (!ParseArgs(argc, argv, &args, &error)) {
    if (!error.empty()) {
      std::cerr << "bopomix-eval: error: " << error << "\n\n";
    }
    PrintUsage(argv[0]);
    return error.empty() ? 0 : 1;
  }

  const std::filesystem::path dataPath = args.dataDir / "data.txt";
  if (!std::filesystem::exists(dataPath)) {
    std::cerr << "bopomix-eval: error: cannot find " << dataPath
              << " under --data " << args.dataDir << "\n";
    return 1;
  }

  auto lm = std::make_shared<McBopomofoLM>();
  lm->loadLanguageModel(dataPath.c_str());
  if (!lm->isDataModelLoaded()) {
    std::cerr << "bopomix-eval: error: failed to load language model from "
              << dataPath << "\n";
    return 1;
  }

  const BopomofoKeyboardLayout* layout = BopomofoKeyboardLayout::StandardLayout();

  LatinLexicon lexicon;
  const LatinLexicon* lexiconPtr = nullptr;
  if (args.mixed) {
    const std::filesystem::path wordsPath = args.lexiconDir / "latin-words.txt";
    const std::filesystem::path techSeedPath =
        args.lexiconDir / "latin-tech-seed.txt";
    if (!lexicon.loadBuiltinWordList(wordsPath.c_str())) {
      std::cerr << "bopomix-eval: error: cannot load " << wordsPath << "\n";
      return 1;
    }
    if (!lexicon.loadBuiltinWordList(techSeedPath.c_str())) {
      std::cerr << "bopomix-eval: error: cannot load " << techSeedPath << "\n";
      return 1;
    }
    lm->setMixedScriptEnabled(true);
    lexiconPtr = &lexicon;
  }

  if (args.mode == "keys") {
    return RunKeysMode(lm, layout, lexiconPtr);
  }
  if (args.mode == "readings") {
    return RunReadingsMode(lm);
  }
  if (args.mode == "keyseq") {
    return RunKeyseqMode(lm, layout);
  }

  std::cerr << "bopomix-eval: error: unreachable mode " << args.mode << "\n";
  return 1;
}
