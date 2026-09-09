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

#include "mixed_script_tracker.h"

namespace McBopomofo::MixedScript {

Verdict MixedScriptTracker::feedKey(
    const Formosa::Mandarin::BopomofoKeyboardLayout* layout, char key) {
  latinRun_.push_back(key);

  if (latinLocked_) {
    return Verdict::kLatin;
  }

  bool stillComposable = shape_.feed(layout, key);
  if (!stillComposable) {
    latinLocked_ = true;
    return Verdict::kLatin;
  }

  if (latinRun_.size() >= kMinAmbiguousWordLength && lexicon_ != nullptr &&
      lexicon_->isWord(latinRun_)) {
    return Verdict::kAmbiguous;
  }
  return Verdict::kChinese;
}

Verdict MixedScriptTracker::onBoundary(bool isSpaceOrEnd) const {
  if (latinLocked_) {
    return Verdict::kLatin;
  }
  bool isDictionaryWord = lexicon_ != nullptr &&
                          latinRun_.size() >= kMinAmbiguousWordLength &&
                          lexicon_->isWord(latinRun_);
  if (!isDictionaryWord) {
    return Verdict::kChinese;
  }
  // Rule B (dictionary word) + rule C (trailing space/end-of-input) =>
  // English by default; rule B alone stays an ambiguous Chinese default
  // with a Latin candidate.
  return isSpaceOrEnd ? Verdict::kLatin : Verdict::kAmbiguous;
}

void MixedScriptTracker::popLastLatinChar() {
  if (latinRun_.empty()) {
    return;
  }
  if (latinLocked_) {
    latinRun_.pop_back();
    return;
  }
  reset();
}

void MixedScriptTracker::reset() {
  shape_.reset();
  latinRun_.clear();
  latinLocked_ = false;
}

bool IsAllAsciiLetters(const std::string& value) {
  if (value.empty()) {
    return false;
  }
  for (unsigned char c : value) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) {
      return false;
    }
  }
  return true;
}

}  // namespace McBopomofo::MixedScript
