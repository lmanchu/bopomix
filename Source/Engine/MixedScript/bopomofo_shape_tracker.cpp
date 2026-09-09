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

#include "bopomofo_shape_tracker.h"

namespace McBopomofo::MixedScript {

using Formosa::Mandarin::BopomofoKeyboardLayout;
using Formosa::Mandarin::BopomofoSyllable;

void BopomofoShapeTracker::reset() {
  stillComposable_ = true;
  hasConsonant_ = false;
  hasMedial_ = false;
  hasVowel_ = false;
  consonant_ = 0;
  medial_ = 0;
  vowel_ = 0;
}

BopomofoShapeTracker::Category BopomofoShapeTracker::categoryFor(
    const BopomofoKeyboardLayout* layout, char key,
    BopomofoSyllable::Component* outComponent) {
  const std::vector<BopomofoSyllable::Component> components =
      layout->keyToComponents(key);
  if (components.empty()) {
    return Category::kNone;
  }
  // The standard layout (the only one mixedScript supports -- see
  // MixedScriptTracker) maps every key to at most one component, so the
  // first candidate is authoritative.
  BopomofoSyllable::Component component = components[0];
  *outComponent = component;
  if (component & BopomofoSyllable::ToneMarkerMask) {
    return Category::kTone;
  }
  if (component & BopomofoSyllable::ConsonantMask) {
    return Category::kConsonant;
  }
  if (component & BopomofoSyllable::MiddleVowelMask) {
    return Category::kMedial;
  }
  if (component & BopomofoSyllable::VowelMask) {
    return Category::kVowel;
  }
  return Category::kNone;
}

bool BopomofoShapeTracker::feed(const BopomofoKeyboardLayout* layout,
                                char key) {
  if (!stillComposable_) {
    return false;
  }

  BopomofoSyllable::Component component = 0;
  Category category = categoryFor(layout, key, &component);

  switch (category) {
    case Category::kNone:
    case Category::kTone:
      // kNone shouldn't happen for a key the caller already validated via
      // isValidKey(); kTone always ends a syllable (KeyHandler
      // force-composes and resets this tracker before another key can
      // arrive), so neither carries shape information to track.
      break;
    case Category::kConsonant:
      if (hasMedial_ || hasVowel_) {
        stillComposable_ = false;  // Consonant after medial/vowel: regression.
      } else if (hasConsonant_ && consonant_ != component) {
        stillComposable_ = false;  // A different consonant was already set.
      } else {
        hasConsonant_ = true;
        consonant_ = component;
      }
      break;
    case Category::kMedial:
      if (hasVowel_) {
        stillComposable_ = false;  // Medial after vowel: regression.
      } else if (hasMedial_ && medial_ != component) {
        stillComposable_ = false;
      } else {
        hasMedial_ = true;
        medial_ = component;
      }
      break;
    case Category::kVowel:
      if (hasVowel_ && vowel_ != component) {
        stillComposable_ = false;
      } else {
        hasVowel_ = true;
        vowel_ = component;
      }
      break;
  }

  return stillComposable_;
}

}  // namespace McBopomofo::MixedScript
