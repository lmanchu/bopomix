// Copyright (c) 2026 and onwards The Mixime Authors.
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
// mixime-eval: a headless CLI harness for the McBopomofo/mixime C++ engine.
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
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "Mandarin/Mandarin.h"
#include "McBopomofoLM.h"
#include "UTF8Helper.h"
#include "gramambular2/reading_grid.h"

namespace {

using Formosa::Gramambular2::ReadingGrid;
using Formosa::Mandarin::BopomofoKeyboardLayout;
using Formosa::Mandarin::BopomofoReadingBuffer;
using Formosa::Mandarin::BopomofoSyllable;
using McBopomofo::McBopomofoLM;

struct Args {
  std::filesystem::path dataDir;
  std::string layout = "standard";
  std::string mode;
};

void PrintUsage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0
      << " --data <ResourcesDir> --mode {keys|readings|keyseq} "
         "[--layout standard]\n"
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
      << "            stdout (tab-separated): readings\\tstandard_keys\n";
}

bool ParseArgs(int argc, char** argv, Args* outArgs, std::string* error) {
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--data" && i + 1 < argc) {
      outArgs->dataDir = argv[++i];
    } else if (arg == "--layout" && i + 1 < argc) {
      outArgs->layout = argv[++i];
    } else if (arg == "--mode" && i + 1 < argc) {
      outArgs->mode = argv[++i];
    } else if (arg == "--help" || arg == "-h") {
      return false;
    } else {
      *error = "unrecognized or incomplete argument: " + arg;
      return false;
    }
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
// off by default) -- this eval harness does not add any English-detection
// logic of its own; that is precisely the gap P1 (F1) is meant to close.
int RunKeysMode(const std::shared_ptr<McBopomofoLM>& lm,
                const BopomofoKeyboardLayout* layout) {
  std::string line;
  while (std::getline(std::cin, line)) {
    line = StripCR(line);

    const auto start = std::chrono::steady_clock::now();

    ReadingGrid grid(lm);
    BopomofoReadingBuffer buffer(layout);
    int uncomposable = 0;

    auto flush = [&]() {
      if (buffer.isEmpty()) {
        return;
      }
      std::string reading = buffer.syllable().composedString();
      if (!grid.insertReading(reading)) {
        ++uncomposable;
      }
      buffer.clear();
    };

    for (char rawKey : line) {
      if (rawKey == ' ') {
        // KeyHandler.mm:516 - space forces composition of a pending
        // (typically tone-1, unmarked) reading. A space with an empty
        // buffer is not a printable character in McBopomofo's default
        // bindings (chooseCandidateUsingSpace is on by default, so it would
        // open a candidate window instead of committing a literal space);
        // this harness has no candidate UI, so it is simply a no-op then.
        flush();
        continue;
      }
      if (buffer.isValidKey(rawKey)) {
        buffer.combineKey(rawKey);
        if (buffer.hasToneMarker() && !buffer.hasToneMarkerOnly()) {
          // KeyHandler.mm:512 - a tone key (with a consonant/vowel already
          // present) immediately triggers composition, no space needed.
          flush();
        }
        continue;
      }
      // A key outside the standard layout's BPMF map. Out of scope for the
      // "keys" mode per the eval harness spec (which only feeds
      // letters/digits/,./;-/space), but handled defensively: flush any
      // pending reading (mirrors the key not being consumed by the reading
      // buffer and falling through in KeyHandler.mm) and skip the key.
      flush();
      std::cerr << "mixime-eval: warning: key '" << rawKey
                << "' is not a standard-layout BPMF key; skipped\n";
    }
    flush();  // Simulate a trailing Enter/commit at end of line.

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
        std::cerr << "mixime-eval: warning: no dictionary reading for "
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
      std::cerr << "mixime-eval: error: " << error << "\n\n";
    }
    PrintUsage(argv[0]);
    return error.empty() ? 0 : 1;
  }

  const std::filesystem::path dataPath = args.dataDir / "data.txt";
  if (!std::filesystem::exists(dataPath)) {
    std::cerr << "mixime-eval: error: cannot find " << dataPath
              << " under --data " << args.dataDir << "\n";
    return 1;
  }

  auto lm = std::make_shared<McBopomofoLM>();
  lm->loadLanguageModel(dataPath.c_str());
  if (!lm->isDataModelLoaded()) {
    std::cerr << "mixime-eval: error: failed to load language model from "
              << dataPath << "\n";
    return 1;
  }

  const BopomofoKeyboardLayout* layout = BopomofoKeyboardLayout::StandardLayout();

  if (args.mode == "keys") {
    return RunKeysMode(lm, layout);
  }
  if (args.mode == "readings") {
    return RunReadingsMode(lm);
  }
  if (args.mode == "keyseq") {
    return RunKeyseqMode(lm, layout);
  }

  std::cerr << "mixime-eval: error: unreachable mode " << args.mode << "\n";
  return 1;
}
