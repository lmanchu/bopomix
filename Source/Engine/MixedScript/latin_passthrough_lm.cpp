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

#include "latin_passthrough_lm.h"

namespace McBopomofo::MixedScript {

void LatinPassthroughLM::registerSoleEntry(const std::string& key,
                                           const std::string& value) {
  entries_[key] = {Formosa::Gramambular2::LanguageModel::Unigram(value, 0)};
}

void LatinPassthroughLM::registerAlternate(const std::string& key,
                                           const std::string& value,
                                           double score) {
  entries_[key].emplace_back(value, score);
}

bool LatinPassthroughLM::hasValue(const std::string& key,
                                  const std::string& value) const {
  auto it = entries_.find(key);
  if (it == entries_.end()) {
    return false;
  }
  for (const auto& unigram : it->second) {
    if (unigram.value() == value) {
      return true;
    }
  }
  return false;
}

void LatinPassthroughLM::clear() { entries_.clear(); }

void LatinPassthroughLM::clearKey(const std::string& key) { entries_.erase(key); }

std::vector<Formosa::Gramambular2::LanguageModel::Unigram>
LatinPassthroughLM::getUnigrams(const std::string& key) {
  auto it = entries_.find(key);
  if (it == entries_.end()) {
    return {};
  }
  return it->second;
}

bool LatinPassthroughLM::hasUnigrams(const std::string& key) {
  auto it = entries_.find(key);
  return it != entries_.end() && !it->second.empty();
}

}  // namespace McBopomofo::MixedScript
