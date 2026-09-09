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

#ifndef SRC_ENGINE_MIXEDSCRIPT_BOPOMOFO_SHAPE_TRACKER_H_
#define SRC_ENGINE_MIXEDSCRIPT_BOPOMOFO_SHAPE_TRACKER_H_

#include "../Mandarin/Mandarin.h"

namespace McBopomofo::MixedScript {

// Answers rule A's question -- "does the Bopomofo shape built from this run
// of keys still look like it could become a legitimately-typed syllable?"
// -- one key at a time, for the *standard* keyboard layout only (the only
// layout mixedScript supports; see MixedScriptTracker's class doc).
//
// Deliberately does NOT call McBopomofoLM::hasUnigrams() on partial state:
// almost every consonant needs a following vowel to become a real
// syllable, so checking hasUnigrams() against an in-progress, vowel-less
// state would also reject completely ordinary Chinese syllables that
// simply have not finished being typed yet -- which would make
// mixedScriptEnabled=true corrupt normal Chinese input. Instead this
// checks that the categories seen so far (consonant -> medial -> vowel,
// tone always terminal) are arriving in a structurally sane order for a
// single syllable, and that no category is given two different values.
// Concretely: a key's category conflicting with, or arriving after, a
// *different* category already established in the same run signals
// "impossible" -- e.g. "th" (t=CH consonant, h=C consonant: two different
// consonants) or "sl" + a third consonant-mapped letter (s=N consonant,
// l=AO vowel, then a consonant key arrives after the vowel was already
// set). Real single-syllable Bopomofo typing does not do either of these
// (there is only one consonant/medial/vowel slot per syllable, and a tone
// key -- which is exempt from this check -- always ends the syllable and
// is composed immediately by KeyHandler, which resets this tracker before
// the next key). See zhuyin-ime-personal.md's P1 design section for the
// quantification this mirrors (~74% of English tokens become
// "uncomposable" within 2-3 letters) and the explicit "th"/"sl" examples.
//
// Known, accepted tradeoff: a legitimate but unusual same-category
// self-correction (typing a second consonant key to replace the first,
// without backspacing) is also flagged as "impossible" and reclassified
// as Latin text. Given "never silently drop a keystroke" is the higher
// priority than "never misclassify," and McBopomofo/mixime does not
// otherwise treat consecutive same-category keys as intentional
// self-correction (there is no existing feature relying on it), showing
// the raw letters (which the user can then see and backspace) is judged
// preferable to what mixedScriptEnabled=false already does with them
// (silently drop, or misrecognize as an unrelated character).
class BopomofoShapeTracker {
 public:
  void reset();

  // Feeds one ASCII key that the caller has already confirmed is a valid
  // Bopomofo key for `layout` (Mandarin::BopomofoReadingBuffer::isValidKey()
  // returned true). Returns stillComposable() after incorporating this
  // key.
  bool feed(const Formosa::Mandarin::BopomofoKeyboardLayout* layout,
            char key);

  // False once a conflicting/regressive key has been fed; stays false
  // until reset().
  bool stillComposable() const { return stillComposable_; }

 private:
  enum class Category { kNone, kConsonant, kMedial, kVowel, kTone };

  static Category categoryFor(
      const Formosa::Mandarin::BopomofoKeyboardLayout* layout, char key,
      Formosa::Mandarin::BopomofoSyllable::Component* outComponent);

  bool stillComposable_ = true;
  bool hasConsonant_ = false;
  bool hasMedial_ = false;
  bool hasVowel_ = false;
  Formosa::Mandarin::BopomofoSyllable::Component consonant_ = 0;
  Formosa::Mandarin::BopomofoSyllable::Component medial_ = 0;
  Formosa::Mandarin::BopomofoSyllable::Component vowel_ = 0;
};

}  // namespace McBopomofo::MixedScript

#endif  // SRC_ENGINE_MIXEDSCRIPT_BOPOMOFO_SHAPE_TRACKER_H_
