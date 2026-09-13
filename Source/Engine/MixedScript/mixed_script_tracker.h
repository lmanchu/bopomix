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
  // Rule A (BopomofoShapeTracker says the shape is dead), or a run that is
  // a word in the *user's own* lexicon confirmed by a trailing
  // space/end-of-input (decided by onBoundary()): this run is English.
  // Once feedKey() returns kLatin, it keeps returning kLatin for the rest
  // of the run (see MixedScriptTracker class doc on latinRun()).
  kLatin,
  // Rule B (dictionary word, shape still alive): genuinely ambiguous. The
  // caller does NOT stop feeding the real reading buffer -- this is not a
  // request to abandon the Chinese path, just a signal to also register
  // latinRun() as a slightly-lower-scored alternate candidate at the
  // current reading, i.e. the candidate window's second row (see
  // LatinPassthroughLM). Only onBoundary(true) on a word the user has
  // personally chosen before can promote this to kLatin.
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
  // Rule B (dictionary-word) never fires below this length. Two letters is
  // far too short: on the standard layout every two-letter run is also an
  // ordinary tone-1 syllable's full key sequence, and an exhaustive sweep
  // of data.txt found 20 single-syllable tone-1 readings whose key
  // sequence is a dictionary word ("up"=ㄧㄣ, "el"=ㄍㄠ, "ai"=ㄇㄛ,
  // "zo"=ㄈㄟ...), 19 of them two letters long -- letting rule B fire on
  // those cost 5.1 points of pure-Chinese accuracy for 13 of 385 English
  // tokens (see docs/REVIEW-P1-2026-09-10.md's B1 and dimension 10).
  // Rule A (structural) is unaffected: it can fire at any length,
  // including 1, since it never consults the dictionary.
  static constexpr size_t kMinAmbiguousWordLength = 3;

  // `lexicon` is not owned and must outlive this tracker (mirrors how
  // McBopomofoLM's other sub-language-models are owned by their parent).
  // May be null, and may change between runs (the app loads the word
  // lists off the key thread and publishes them when ready -- see
  // LanguageModelManager's +latinLexicon); a null lexicon simply means
  // rules B/C never fire and only rule A's structural check applies.
  explicit MixedScriptTracker(const LatinLexicon* lexicon)
      : lexicon_(lexicon) {}

  void setLexicon(const LatinLexicon* lexicon) { lexicon_ = lexicon; }

  // Feeds one ASCII letter key, already confirmed by the caller to be a
  // valid Bopomofo key for `layout` (isValidKey()) -- callers are expected
  // to route non-letter and non-Bopomofo keys to onBoundary() instead.
  // Returns the verdict for the run as of this key.
  Verdict feedKey(const Formosa::Mandarin::BopomofoKeyboardLayout* layout,
                  char key);

  // Called when a run ends: a non-letter key, or end of input.
  // `isSpaceOrEnd` is true for an actual space or end-of-input, false for
  // any other boundary (a tone-marker key, punctuation...).
  //
  // A trailing space auto-commits the run as English only when it is a
  // word in the user's *own* lexicon (LatinLexicon::isUserWord() -- a word
  // this user has previously picked by hand). The 2026-09-09
  // "詞典＋空白→英文" rule used the whole 200k built-in list here, which
  // is fundamentally in conflict with how tone 1 is typed on this layout
  // (space *is* the tone-1 key), so it rewrote ordinary Chinese: "up " no
  // longer produced 因, "fu/ " no longer produced 清. Superseded
  // 2026-09-10 (see docs/REVIEW-P1-2026-09-10.md's B1/B2); a run that is
  // merely in the built-in dictionary now stays kAmbiguous, i.e. Chinese
  // by default with the English form one Tab away.
  //
  // Returns the final verdict. Does not clear latinRun() -- callers still
  // need it to build the literal-text node/candidate; call reset() once
  // done with it.
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
  // already Latin-locked, this shortens latinRun() (rule A's verdict
  // cannot become "un-decided" by removing a trailing character) -- and,
  // when that empties the run, drops the lock too: there is no run left to
  // be locked, and leaving latinLocked_ set would silently turn every
  // following Bopomofo key into English until the user found a non-letter
  // key to escape with (see docs/REVIEW-P1-2026-09-10.md's B5).
  // Otherwise -- a merely ambiguous or plain-Chinese run, still backed by
  // the real BopomofoReadingBuffer -- correctly rewinding
  // BopomofoShapeTracker's internal state would need full key-history
  // replay; this instead just resets the whole run (a known, documented
  // P1 simplification: backspacing mid-run falls back to plain Chinese
  // tracking for what remains of it rather than mis-tracking it). The
  // caller's own BopomofoReadingBuffer::backspace() is unaffected either
  // way -- this only touches mixedScript's own bookkeeping.
  void popLastLatinChar();

  // P3 predictive typing (see zhuyin-ime-personal.md's F3 scope and
  // LatinLexicon::complete()): replaces the pending run's text with a
  // longer completion the user just accepted (Tab, or a pick from the
  // completion candidate window -- see KeyHandler's mixed-script hookup).
  // Only meaningful while isLatinLocked() is already true -- accepting a
  // completion is only offered for a Rule-A-locked run in the first place
  // (see buildInputtingState's tooltip and the Tab hookup) -- but locks
  // the run regardless, so calling it is never a no-op: latinRun()
  // reflects `word` and isLatinLocked() is true either way afterward, and
  // further letters typed continue to extend it as English exactly like
  // any other locked run. Also marks the run as "already remembered" (see
  // latinRunAlreadyRemembered()), since accepting a completion already
  // writes it to the user's lexicon (KeyHandler's
  // _acceptLatinCompletionWord:); feedKey()/popLastLatinChar() clear that
  // flag again the moment the run's text changes.
  void acceptCompletion(const std::string& word);

  // P3 "learn from what you actually type" (see
  // zhuyin-ime-personal.md's P3 fix #2): true if the run's *current* text
  // was already explicitly written to the user's lexicon by a completion
  // accept (acceptCompletion()) and has not changed since. KeyHandler's
  // _commitMixedScriptLatinRun uses this to avoid double-counting a word
  // Tab/the candidate window already remembered when that same run later
  // reaches an ordinary boundary commit (Enter/space/punctuation) --
  // without it, accepting "th" -> "throughput" via Tab and then pressing
  // Enter would bump "throughput"'s use count twice for one accept.
  bool latinRunAlreadyRemembered() const { return alreadyRemembered_; }

  void reset();

 private:
  const LatinLexicon* lexicon_;
  BopomofoShapeTracker shape_;
  std::string latinRun_;
  bool latinLocked_ = false;
  bool alreadyRemembered_ = false;
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
