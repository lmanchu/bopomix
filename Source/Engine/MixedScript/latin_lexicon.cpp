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

#include "latin_lexicon.h"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <fstream>
#include <sstream>

namespace McBopomofo::MixedScript {

std::string LatinLexicon::ToLowerAscii(const std::string& text) {
  std::string result = text;
  std::transform(result.begin(), result.end(), result.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return result;
}

namespace {
bool LessByPointee(const std::string* a, const std::string* b) {
  return *a < *b;
}
}  // namespace

void LatinLexicon::mergeNewSortedWords(size_t oldSize) {
  if (sortedWords_.size() == oldSize) {
    return;
  }
  auto newBegin = sortedWords_.begin() + static_cast<std::ptrdiff_t>(oldSize);
  // The bundled lists are emitted already sorted (see
  // tools/lexicon/build_lexicon.py), so this is normally just the O(n)
  // is_sorted check plus the merge; sorting is the fallback for a
  // hand-edited or user-written file.
  if (!std::is_sorted(newBegin, sortedWords_.end(), LessByPointee)) {
    std::sort(newBegin, sortedWords_.end(), LessByPointee);
  }
  std::inplace_merge(sortedWords_.begin(), newBegin, sortedWords_.end(),
                     LessByPointee);
}

bool LatinLexicon::loadBuiltinWordList(const std::string& path) {
  std::ifstream file(path);
  if (!file.is_open()) {
    return false;
  }

  const size_t sortedSizeBefore = sortedWords_.size();
  std::string line;
  while (std::getline(file, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.empty() || line[0] == '#') {
      continue;
    }

    std::string word = line;
    int rank = -1;
    size_t tab = line.find('\t');
    if (tab != std::string::npos) {
      word = line.substr(0, tab);
      std::istringstream rankStream(line.substr(tab + 1));
      rankStream >> rank;
    }
    if (word.empty()) {
      continue;
    }

    std::string lowerWord = ToLowerAscii(word);
    if (rank < 0) {
      rank = nextBuiltinRank_;
    }
    nextBuiltinRank_ = std::max(nextBuiltinRank_, rank + 1);

    auto existing = builtinRank_.find(lowerWord);
    if (existing == builtinRank_.end()) {
      auto inserted = builtinRank_.emplace(lowerWord, rank).first;
      if (userWords_.find(lowerWord) == userWords_.end()) {
        sortedWords_.push_back(&inserted->first);
      }
    } else if (rank < existing->second) {
      existing->second = rank;
    }
  }
  mergeNewSortedWords(sortedSizeBefore);
  return true;
}

bool LatinLexicon::loadUserWordList(const std::string& path) {
  std::ifstream file(path);
  if (!file.is_open()) {
    // Missing file is expected on first run; not an error.
    return false;
  }

  const size_t sortedSizeBefore = sortedWords_.size();
  std::string line;
  while (std::getline(file, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.empty() || line[0] == '#') {
      continue;
    }
    std::string lowerWord = ToLowerAscii(line);
    auto inserted = userWords_.insert(lowerWord);
    if (inserted.second && builtinRank_.find(lowerWord) == builtinRank_.end()) {
      sortedWords_.push_back(&(*inserted.first));
    }
  }
  mergeNewSortedWords(sortedSizeBefore);
  return true;
}

bool LatinLexicon::isWord(const std::string& text) const {
  if (text.size() < 2) {
    return false;
  }
  std::string lowerText = ToLowerAscii(text);
  return builtinRank_.find(lowerText) != builtinRank_.end() ||
         userWords_.find(lowerText) != userWords_.end();
}

bool LatinLexicon::isUserWord(const std::string& text) const {
  if (text.empty()) {
    return false;
  }
  return userWords_.find(ToLowerAscii(text)) != userWords_.end();
}

bool LatinLexicon::isPrefix(const std::string& text) const {
  if (text.empty()) {
    return true;
  }
  std::string lowerText = ToLowerAscii(text);
  auto it = std::lower_bound(
      sortedWords_.begin(), sortedWords_.end(), lowerText,
      [](const std::string* a, const std::string& b) { return *a < b; });
  return it != sortedWords_.end() &&
         (*it)->compare(0, lowerText.size(), lowerText) == 0;
}

int LatinLexicon::rank(const std::string& text) const {
  std::string lowerText = ToLowerAscii(text);
  if (userWords_.find(lowerText) != userWords_.end()) {
    return 0;
  }
  auto it = builtinRank_.find(lowerText);
  if (it != builtinRank_.end()) {
    return it->second;
  }
  return -1;
}

bool LatinLexicon::rememberWord(const std::string& word) {
  if (word.size() < 2) {
    return true;
  }
  std::string lowerWord = ToLowerAscii(word);
  auto inserted = userWords_.insert(lowerWord);
  if (!inserted.second) {
    return true;
  }
  if (builtinRank_.find(lowerWord) == builtinRank_.end()) {
    auto position =
        std::lower_bound(sortedWords_.begin(), sortedWords_.end(), lowerWord,
                         [](const std::string* a, const std::string& b) {
                           return *a < b;
                         });
    sortedWords_.insert(position, &(*inserted.first));
  }

  if (userWordListPath_.empty()) {
    return true;
  }
  std::ofstream file(userWordListPath_, std::ios::app);
  if (!file.is_open()) {
    return false;
  }
  file << lowerWord << "\n";
  file.flush();
  // The word is already live in memory either way; the return value only
  // tells the caller whether it will still be there next launch.
  return file.good();
}

}  // namespace McBopomofo::MixedScript
