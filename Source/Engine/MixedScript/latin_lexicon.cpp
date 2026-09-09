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
#include <fstream>
#include <sstream>

namespace McBopomofo::MixedScript {

std::string LatinLexicon::ToLowerAscii(const std::string& text) {
  std::string result = text;
  std::transform(result.begin(), result.end(), result.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return result;
}

void LatinLexicon::ensureSortedWords() const {
  if (!sortedWordsStale_) {
    return;
  }
  sortedWords_.clear();
  sortedWords_.reserve(builtinRank_.size() + userWords_.size());
  for (const auto& [word, unusedRank] : builtinRank_) {
    sortedWords_.push_back(word);
  }
  for (const std::string& word : userWords_) {
    sortedWords_.push_back(word);
  }
  std::sort(sortedWords_.begin(), sortedWords_.end());
  sortedWordsStale_ = false;
}

bool LatinLexicon::loadBuiltinWordList(const std::string& path) {
  std::ifstream file(path);
  if (!file.is_open()) {
    return false;
  }

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
    if (existing == builtinRank_.end() || rank < existing->second) {
      builtinRank_[lowerWord] = rank;
    }
  }
  sortedWordsStale_ = true;
  return true;
}

bool LatinLexicon::loadUserWordList(const std::string& path) {
  std::ifstream file(path);
  if (!file.is_open()) {
    // Missing file is expected on first run; not an error.
    return false;
  }

  std::string line;
  while (std::getline(file, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.empty() || line[0] == '#') {
      continue;
    }
    std::string lowerWord = ToLowerAscii(line);
    userWords_.insert(lowerWord);
  }
  sortedWordsStale_ = true;
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

bool LatinLexicon::isPrefix(const std::string& text) const {
  if (text.empty()) {
    return true;
  }
  ensureSortedWords();
  std::string lowerText = ToLowerAscii(text);
  auto it = std::lower_bound(sortedWords_.begin(), sortedWords_.end(), lowerText);
  return it != sortedWords_.end() &&
         it->compare(0, lowerText.size(), lowerText) == 0;
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

void LatinLexicon::rememberWord(const std::string& word) {
  if (word.size() < 2) {
    return;
  }
  std::string lowerWord = ToLowerAscii(word);
  if (userWords_.find(lowerWord) != userWords_.end()) {
    return;
  }
  userWords_.insert(lowerWord);
  sortedWordsStale_ = true;

  if (!userWordListPath_.empty()) {
    std::ofstream file(userWordListPath_, std::ios::app);
    if (file.is_open()) {
      file << lowerWord << "\n";
    }
  }
}

}  // namespace McBopomofo::MixedScript
