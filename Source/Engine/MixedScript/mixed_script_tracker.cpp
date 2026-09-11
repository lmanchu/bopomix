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
  // A trailing space promotes a still-composable run to English only for
  // words in the user's own lexicon -- words they have explicitly chosen
  // as English before. See the header for why the built-in list cannot be
  // used here (space is the tone-1 key).
  if (isSpaceOrEnd && lexicon_->isUserWord(latinRun_)) {
    return Verdict::kLatin;
  }
  return Verdict::kAmbiguous;
}

void MixedScriptTracker::popLastLatinChar() {
  if (latinRun_.empty()) {
    return;
  }
  if (latinLocked_) {
    latinRun_.pop_back();
    if (latinRun_.empty()) {
      reset();
    }
    return;
  }
  reset();
}

void MixedScriptTracker::acceptCompletion(const std::string& word) {
  latinRun_ = word;
  latinLocked_ = true;
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
