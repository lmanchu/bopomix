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

#ifndef SRC_ENGINE_MIXEDSCRIPT_LATIN_PASSTHROUGH_LM_H_
#define SRC_ENGINE_MIXEDSCRIPT_LATIN_PASSTHROUGH_LM_H_

#include <string>
#include <unordered_map>
#include <vector>

#include "../gramambular2/language_model.h"

namespace McBopomofo::MixedScript {

// A tiny, purely in-memory, session-only LanguageModel that lets a literal
// ASCII run (e.g. "the", "acer") appear as a ReadingGrid unigram value,
// merged into McBopomofoLM's normal getUnigrams()/hasUnigrams() dispatch
// (see McBopomofoLM::setMixedScriptEnabled()). Two call patterns, matching
// MixedScriptTracker::Verdict:
//
//  - Rule A (kLatin): registerSoleEntry(syntheticKey, text) under a key
//    that only mixedScript ever inserts (see KeyHandler's "_latin_"-
//    prefixed keys), so it is the only unigram found and always wins.
//  - Rule B (kAmbiguous): registerAlternate(existingReading, text, score)
//    under the *same* reading the normal Chinese path already produced
//    for the current syllable, with the score the caller gets from
//    ScoreJustBelow(topUnigramScore) -- just under the reading's best
//    Chinese unigram, so Chinese still wins the Viterbi walk by default
//    but the English form lands on the candidate window's *second* row
//    and is one Tab away.
//
//    How candidate order actually works (the reason a fixed -99 score was
//    wrong -- see docs/REVIEW-P1-2026-09-10.md's N2):
//    ReadingGrid::candidatesAt() stable_sorts the *nodes* overlapping the
//    location by spanning length, longest first, and then emits each
//    node's unigrams in the order that node holds them -- which, because
//    ReadingGrid wraps the language model in ScoreRankedLanguageModel, is
//    strictly descending by score. So a candidate's row within its own
//    node is decided purely by its score, and -99 put the English form
//    dead last, 50-70 Tab presses away for a common syllable.
//
// Entries are never written to disk: unlike LatinLexicon's user word list,
// this only needs to last for the current composing session (the grid
// itself is cleared on every commit), so there's nothing to persist here.
class LatinPassthroughLM : public Formosa::Gramambular2::LanguageModel {
 public:
  // How far below the reading's top unigram a rule-B alternate is placed.
  // Small enough that nothing real can sit between the two (unigram
  // scores in data.txt are log probabilities spaced far wider than this),
  // large enough to survive double rounding.
  static constexpr double kAlternateScoreEpsilon = 1e-4;

  // The score to register a rule-B alternate with, given the highest
  // score among the reading's existing (Chinese) unigrams.
  static constexpr double ScoreJustBelow(double topUnigramScore) {
    return topUnigramScore - kAlternateScoreEpsilon;
  }

  void registerSoleEntry(const std::string& key, const std::string& value);
  void registerAlternate(const std::string& key, const std::string& value,
                         double score);

  // True if `value` was registered (via either method above) under `key`.
  // KeyHandler uses this at candidate-selection time (Tab or the candidate
  // window -- both funnel through fixNodeWithReading:) to tell whether the
  // user just explicitly picked a mixedScript Latin candidate, which is
  // when (and only when) LatinLexicon::rememberWord() should be called --
  // see the design notes' P1 design notes on why the automatic
  // dictionary-plus-space default must NOT itself count as learning.
  bool hasValue(const std::string& key, const std::string& value) const;

  // Drops all registrations. KeyHandler calls this whenever the grid
  // itself is cleared (commit, mode switch, Esc-to-clear) so a stale
  // synthetic key from a previous composition never lingers.
  void clear();

  // Drops just `key`'s registration. The underlying McBopomofoLM instance
  // (and therefore this LM) is process-wide, shared by every KeyHandler
  // instance/text field (see LanguageModelManager) -- KeyHandler calls
  // this immediately after a registered entry has been consumed by
  // ReadingGrid::insertReading() (which snapshots unigrams into an
  // immutable Node at insert time, so the registration is no longer
  // needed for that insertion), rather than waiting for the next clear(),
  // so an unrelated KeyHandler instance/text field can never observe a
  // stale entry for a reading it happens to type normally afterward.
  void clearKey(const std::string& key);

  std::vector<Formosa::Gramambular2::LanguageModel::Unigram> getUnigrams(
      const std::string& key) override;
  bool hasUnigrams(const std::string& key) override;

 private:
  std::unordered_map<std::string,
                     std::vector<Formosa::Gramambular2::LanguageModel::Unigram>>
      entries_;
};

}  // namespace McBopomofo::MixedScript

#endif  // SRC_ENGINE_MIXEDSCRIPT_LATIN_PASSTHROUGH_LM_H_
