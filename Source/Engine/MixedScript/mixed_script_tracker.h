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

#ifndef SRC_ENGINE_MIXEDSCRIPT_MIXED_SCRIPT_TRACKER_H_
#define SRC_ENGINE_MIXEDSCRIPT_MIXED_SCRIPT_TRACKER_H_

#include <string>

#include "../Mandarin/Mandarin.h"
#include "bopomofo_shape_tracker.h"
#include "latin_lexicon.h"

namespace McBopomofo::MixedScript {

// The three-way call for one contiguous run of ASCII letters typed without
// leaving Bopomofo mode. See zhuyin-ime-personal.md's P1 design section
// for the product rationale.
enum class Verdict {
  // No English signal (yet). Caller keeps feeding the real
  // BopomofoReadingBuffer normally.
  kChinese,
  // Rule A (BopomofoShapeTracker says the shape is dead) or rule B+C
  // (dictionary word confirmed by a trailing space/end-of-input, decided
  // by onBoundary()): this run is English. Once feedKey() returns kLatin,
  // it keeps returning kLatin for the rest of the run (see
  // MixedScriptTracker class doc on latinRun()).
  kLatin,
  // Rule B only (dictionary word, shape still alive, no boundary
  // confirmation yet): genuinely ambiguous. The caller does NOT stop
  // feeding the real reading buffer -- this is not a request to abandon
  // the Chinese path, just a signal to also register latinRun() as a
  // lower-scored alternate candidate at the current reading (see
  // LatinPassthroughLM). Only onBoundary(true) can promote this to
  // kLatin.
  kAmbiguous,
};

// Tracks one contiguous run of ASCII letters (a run ends at the first
// non-letter key, a space, or end of input -- see onBoundary()) typed
// without leaving Bopomofo mode, combining BopomofoShapeTracker (rule A)
// and LatinLexicon (rules B/C) into the single decision KeyHandler and the
// eval harness both need. Only the standard keyboard layout is supported
// (matching mixedScript's other components and the eval harness -- see
// tools/eval/README.md).
class MixedScriptTracker {
 public:
  // Rule B (dictionary-word) never fires below this length -- a bare
  // "a"/"i" hijacking every Bopomofo key that happens to also be a
  // one-letter English word would be far more disruptive than useful.
  // Rule A (structural) is unaffected: it can fire at any length,
  // including 1, since it never consults the dictionary.
  static constexpr size_t kMinAmbiguousWordLength = 2;

  // `lexicon` is not owned and must outlive this tracker (mirrors how
  // McBopomofoLM's other sub-language-models are owned by their parent).
  explicit MixedScriptTracker(const LatinLexicon* lexicon)
      : lexicon_(lexicon) {}

  // Feeds one ASCII letter key, already confirmed by the caller to be a
  // valid Bopomofo key for `layout` (isValidKey()) -- callers are expected
  // to route non-letter and non-Bopomofo keys to onBoundary() instead.
  // Returns the verdict for the run as of this key.
  Verdict feedKey(const Formosa::Mandarin::BopomofoKeyboardLayout* layout,
                  char key);

  // Called when a run ends: a non-letter key, or end of input.
  // `isSpaceOrEnd` is true for an actual space or end-of-input (rule C's
  // trailing-space signal, per the 2026-09-09 decision "詞典＋空白→英文");
  // false for any other boundary (e.g. a tone-marker key, or punctuation),
  // which leaves a merely-ambiguous run as a Chinese default with a Latin
  // candidate rather than auto-promoting it. Returns the final verdict.
  // Does not clear latinRun() -- callers still need it to build the
  // literal-text node/candidate; call reset() once done with it.
  Verdict onBoundary(bool isSpaceOrEnd) const;

  // The literal ASCII text typed for the run so far, in the exact case the
  // user typed it (LatinLexicon does its own case folding for lookups, so
  // this is never altered here) -- this is what ends up as the composed
  // value for a Latin node, satisfying "the composing buffer always shows
  // the original letters."
  const std::string& latinRun() const { return latinRun_; }

  // True once a run has started (latinRun() non-empty) and has not been
  // reset yet.
  bool hasPendingRun() const { return !latinRun_.empty(); }

  // True once rule A has fired for this run (feedKey() returned kLatin at
  // least once) -- callers use this to know that the *rest* of the run's
  // keys should skip the real BopomofoReadingBuffer entirely rather than
  // re-checking shape/dictionary state on every key.
  bool isLatinLocked() const { return latinLocked_; }

  // Undoes one character of the pending run, for backspace. If the run is
  // already Latin-locked, this simply shortens latinRun() (rule A's
  // verdict cannot become "un-decided" by removing a trailing character).
  // Otherwise -- a merely ambiguous or plain-Chinese run, still backed by
  // the real BopomofoReadingBuffer -- correctly rewinding
  // BopomofoShapeTracker's internal state would need full key-history
  // replay; this instead just resets the whole run (a known, documented
  // P1 simplification: backspacing mid-run falls back to plain Chinese
  // tracking for what remains of it rather than mis-tracking it). The
  // caller's own BopomofoReadingBuffer::backspace() is unaffected either
  // way -- this only touches mixedScript's own bookkeeping.
  void popLastLatinChar();

  void reset();

 private:
  const LatinLexicon* lexicon_;
  BopomofoShapeTracker shape_;
  std::string latinRun_;
  bool latinLocked_ = false;
};

// True if `value` is non-empty and every byte is an ASCII letter. Used at
// candidate-selection time (KeyHandler's fixNodeWithReading:, reached by
// both Tab and the candidate window) to decide whether the user just
// explicitly picked a mixedScript Latin candidate and should have it
// learned into their lexicon (LatinLexicon::rememberWord()) -- checking
// against LatinPassthroughLM directly does not work there, because its
// per-reading registrations are deliberately cleared again within the
// same key event that creates them (see LatinPassthroughLM's class doc
// and KeyHandler's _commitMixedScriptLatinRun), long before a later,
// separate Tab/candidate-window key event could see them. In practice
// this is a reliable signal on its own: McBopomofo's own dictionary
// values are Chinese characters/punctuation, never plain ASCII letters.
bool IsAllAsciiLetters(const std::string& value);

}  // namespace McBopomofo::MixedScript

#endif  // SRC_ENGINE_MIXEDSCRIPT_MIXED_SCRIPT_TRACKER_H_
