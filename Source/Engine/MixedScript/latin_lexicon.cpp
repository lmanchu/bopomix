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
  // See the header's loadBuiltinWordList() doc: an explicit rank in this
  // file is relative to the file itself, so it is offset by whatever
  // range earlier-loaded files already claimed.
  const int rankOffsetForThisFile = nextBuiltinRank_;
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
    } else {
      rank += rankOffsetForThisFile;
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

    std::string word = line;
    int count = 1;
    size_t tab = line.find('\t');
    if (tab != std::string::npos) {
      word = line.substr(0, tab);
      std::istringstream countStream(line.substr(tab + 1));
      countStream >> count;
      if (count < 1) {
        count = 1;
      }
    }
    if (word.empty()) {
      continue;
    }

    std::string lowerWord = ToLowerAscii(word);
    auto existing = userWords_.find(lowerWord);
    if (existing == userWords_.end()) {
      auto inserted = userWords_.emplace(lowerWord, count).first;
      if (builtinRank_.find(lowerWord) == builtinRank_.end()) {
        sortedWords_.push_back(&inserted->first);
      }
    } else {
      // Loading the same word twice (e.g. a hand-edited file) sums the
      // counts rather than picking one arbitrarily.
      existing->second += count;
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

std::vector<std::string> LatinLexicon::complete(const std::string& prefix,
                                                  size_t n) const {
  std::vector<std::string> results;
  if (n == 0 || prefix.empty()) {
    return results;
  }
  std::string lowerPrefix = ToLowerAscii(prefix);
  auto begin = std::lower_bound(
      sortedWords_.begin(), sortedWords_.end(), lowerPrefix,
      [](const std::string* a, const std::string& b) { return *a < b; });

  struct Candidate {
    int tier;             // 0 = user's own lexicon, 1 = everything else.
    long long secondary;  // Smaller is better within a tier.
    const std::string* word;
  };
  // Smaller is a BETTER completion; std::sort's ascending order then puts
  // the best completions first.
  auto better = [](const Candidate& a, const Candidate& b) {
    if (a.tier != b.tier) {
      return a.tier < b.tier;
    }
    if (a.secondary != b.secondary) {
      return a.secondary < b.secondary;
    }
    return *a.word < *b.word;
  };
  // The reverse relation, used to keep a fixed-size max-heap of "the
  // current top-n candidates" whose front is always the single WORST of
  // them -- the one an incoming candidate needs to beat to displace.
  auto worse = [&better](const Candidate& a, const Candidate& b) {
    return better(b, a);
  };

  std::vector<Candidate> best;
  best.reserve(n);
  for (auto it = begin; it != sortedWords_.end(); ++it) {
    const std::string& word = **it;
    if (word.compare(0, lowerPrefix.size(), lowerPrefix) != 0) {
      break;  // sortedWords_ is ordered, so no further entries can match.
    }
    if (word.size() == lowerPrefix.size()) {
      continue;  // Exclude the prefix itself; only longer completions count.
    }

    Candidate candidate { 1, 0, &word };
    auto userIt = userWords_.find(word);
    if (userIt != userWords_.end()) {
      candidate.tier = 0;
      candidate.secondary = -static_cast<long long>(userIt->second);
    } else {
      auto builtinIt = builtinRank_.find(word);
      candidate.secondary =
          builtinIt != builtinRank_.end() ? builtinIt->second : 0;
    }

    if (best.size() < n) {
      best.push_back(candidate);
      std::push_heap(best.begin(), best.end(), worse);
    } else if (worse(best.front(), candidate)) {
      std::pop_heap(best.begin(), best.end(), worse);
      best.back() = candidate;
      std::push_heap(best.begin(), best.end(), worse);
    }
  }

  std::sort(best.begin(), best.end(), better);
  results.reserve(best.size());
  for (const auto& candidate : best) {
    results.push_back(*candidate.word);
  }
  return results;
}

bool LatinLexicon::persistUserWords() const {
  if (userWordListPath_.empty()) {
    return true;
  }
  // rememberWord() only ever changes one word's count, but that word may
  // already be anywhere in the file -- an append-only write can no longer
  // express "this existing word's count went up", so the whole (small)
  // user list is rewritten instead. std::ios::trunc discards the old
  // content first, matching a full-file overwrite.
  std::ofstream file(userWordListPath_, std::ios::trunc);
  if (!file.is_open()) {
    return false;
  }
  for (const auto& entry : userWords_) {
    file << entry.first << "\t" << entry.second << "\n";
  }
  file.flush();
  return file.good();
}

void LatinLexicon::reset() {
  builtinRank_.clear();
  userWords_.clear();
  sortedWords_.clear();
  userWordListPath_.clear();
  nextBuiltinRank_ = 0;
}

bool LatinLexicon::rememberWord(const std::string& word) {
  if (word.size() < 2) {
    return true;
  }
  std::string lowerWord = ToLowerAscii(word);
  auto existing = userWords_.find(lowerWord);
  if (existing == userWords_.end()) {
    auto inserted = userWords_.emplace(lowerWord, 1).first;
    if (builtinRank_.find(lowerWord) == builtinRank_.end()) {
      auto position =
          std::lower_bound(sortedWords_.begin(), sortedWords_.end(), lowerWord,
                           [](const std::string* a, const std::string& b) {
                             return *a < b;
                           });
      sortedWords_.insert(position, &(inserted->first));
    }
  } else {
    existing->second += 1;
  }

  // The word (and its up-to-date count) is already live in memory either
  // way; the return value only tells the caller whether it will still be
  // there, with this count, next launch.
  return persistUserWords();
}

}  // namespace McBopomofo::MixedScript
