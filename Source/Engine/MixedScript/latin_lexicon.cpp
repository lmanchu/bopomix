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

#include "latin_lexicon.h"

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdio>
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

// One line of a user word list ("word" or "word\tcount"), as both
// loadUserWordList() and persistUserWords()'s read-back half parse it.
// Returns false for a line that carries no word at all (blank, comment).
// `*count` is clamped to at least 1, and a bare word means 1, so a P1-era
// file (written before P3 added counting) round-trips unchanged.
bool ParseUserWordLine(const std::string& rawLine, std::string* word,
                       int* count) {
  std::string line = rawLine;
  if (!line.empty() && line.back() == '\r') {
    line.pop_back();
  }
  if (line.empty() || line[0] == '#') {
    return false;
  }
  *word = line;
  *count = 1;
  size_t tab = line.find('\t');
  if (tab != std::string::npos) {
    *word = line.substr(0, tab);
    std::istringstream countStream(line.substr(tab + 1));
    countStream >> *count;
    if (*count < 1) {
      *count = 1;
    }
  }
  return !word->empty();
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
  // Remembering where each file's range starts is what lets sourceTier()
  // recover a word's *in-file* rank (the dictionary's SCOWL tier) from
  // the single merged rank scale.
  builtinFileRankStarts_.push_back(rankOffsetForThisFile);
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
    std::string word;
    int count = 1;
    if (!ParseUserWordLine(line, &word, &count)) {
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

void LatinLexicon::reloadUserWordList(const std::string& path) {
  // sortedWords_ points at keys inside builtinRank_ *and* userWords_;
  // loadUserWordList() only pushes a user word when the builtin store
  // does not already have it, so "not in builtinRank_" identifies
  // exactly the pointers that are about to dangle. Dropping them with a
  // stable remove_if keeps the rest of the vector ordered, which is what
  // the binary searches in isPrefix()/complete() rely on.
  sortedWords_.erase(
      std::remove_if(sortedWords_.begin(), sortedWords_.end(),
                     [this](const std::string* word) {
                       return builtinRank_.find(*word) == builtinRank_.end();
                     }),
      sortedWords_.end());
  userWords_.clear();
  userWordListPath_ = path;
  loadUserWordList(path);
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

int LatinLexicon::builtinTierForRank(int wordRank) const {
  // The last range that starts at or before this rank is the file the
  // word came from; ranks are assigned in load order, so the starts are
  // already ascending.
  size_t fileIndex = 0;
  for (size_t i = 0; i < builtinFileRankStarts_.size(); ++i) {
    if (wordRank < builtinFileRankStarts_[i]) {
      break;
    }
    fileIndex = i;
  }
  if (fileIndex == 0) {
    // The hand-ranked seed list: its internal 0..n ordering is a
    // preference between seed terms, not a frequency tier, so the whole
    // file is one level -- deliberately the *same* level as the
    // dictionary's most frequent tier rather than ahead of it. See the
    // header's sourceTier() doc.
    return kBestSourceTier;
  }
  return kBestSourceTier +
         (wordRank - builtinFileRankStarts_[fileIndex]);
}

int LatinLexicon::sourceTier(const std::string& text) const {
  std::string lowerText = ToLowerAscii(text);
  auto userIt = userWords_.find(lowerText);
  if (userIt != userWords_.end() && userIt->second >= kUserWordConfirmedScore) {
    return kConfirmedUserWordTier;
  }
  auto builtinIt = builtinRank_.find(lowerText);
  if (builtinIt != builtinRank_.end()) {
    return builtinTierForRank(builtinIt->second);
  }
  if (userIt != userWords_.end()) {
    // An unconfirmed user word the dictionary does not know: a real word
    // for isWord() purposes, but with no frequency evidence behind it, so
    // it gets the worst tier rather than a made-up good one.
    return kUnrankedSourceTier;
  }
  return kUnknownSourceTier;
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
    int tier;             // 0 = confirmed user word, 1 = everything else.
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
    if (userIt != userWords_.end() && userIt->second >= kUserWordConfirmedScore) {
      // Only a *confirmed* user word outranks the whole dictionary -- see
      // the header's rememberWord()/complete() docs for why a score of 1
      // (one passive sighting of a word the dictionary already knows) is
      // deliberately not enough.
      candidate.tier = 0;
      candidate.secondary = -static_cast<long long>(userIt->second);
    } else {
      auto builtinIt = builtinRank_.find(word);
      if (builtinIt == builtinRank_.end()) {
        // An unconfirmed word the dictionary has never heard of: one
        // typed sighting staged on disk (see rememberWord()), a
        // hand-edited line, or a pre-P3 file. It is a *record*, not a
        // suggestion -- offering it here is what B2 was about -- so it is
        // skipped entirely rather than sorted last.
        continue;
      }
      candidate.secondary = builtinIt->second;
    }

    // std::push_heap/pop_heap with comparator `comp` keep front() at the
    // comp-MAXIMUM, so `better` (smaller is better) is what makes front()
    // the worst of the current top-n -- the one an incoming candidate has
    // to beat. Using the reversed relation here instead put the *best*
    // candidate at front() and then popped it on every improvement, which
    // discarded essentially everything scanned after the first n words
    // (docs/REVIEW-P3-2026-09-11.md's B1).
    if (best.size() < n) {
      best.push_back(candidate);
      std::push_heap(best.begin(), best.end(), better);
    } else if (better(candidate, best.front())) {
      std::pop_heap(best.begin(), best.end(), better);
      best.back() = candidate;
      std::push_heap(best.begin(), best.end(), better);
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
  // already be anywhere in the file -- an append-only write cannot
  // express "this existing word's count went up" -- so the whole (small)
  // user list is rewritten.
  //
  // What is rewritten is userWords_ merged *into* whatever the file holds
  // right now, per word the larger count winning, not userWords_ on its
  // own. The file is not guaranteed to be the one this process loaded:
  // the user can move the user-phrase folder mid-session and the folder
  // is often inside Dropbox, so the target may hold words this process
  // has never seen. Truncating it deleted them
  // (docs/REVERIFY-P3-2026-09-12.md's P-1).
  std::unordered_map<std::string, int> merged;
  {
    std::ifstream existing(userWordListPath_);
    std::string line;
    while (std::getline(existing, line)) {
      std::string word;
      int count = 1;
      if (!ParseUserWordLine(line, &word, &count)) {
        continue;
      }
      int& stored = merged[ToLowerAscii(word)];
      stored = std::max(stored, count);
    }
  }
  for (const auto& entry : userWords_) {
    int& stored = merged[entry.first];
    stored = std::max(stored, entry.second);
  }

  // Write a sibling temp file and rename it over the target: rename(2)
  // within one directory is atomic, so a crash or a full disk mid-write
  // leaves either the old list or the new one, never a half-written file
  // where the user's vocabulary used to be.
  const std::string tempPath = userWordListPath_ + ".tmp";
  {
    std::ofstream file(tempPath, std::ios::trunc);
    if (!file.is_open()) {
      return false;
    }
    for (const auto& entry : merged) {
      file << entry.first << "\t" << entry.second << "\n";
    }
    file.flush();
    if (!file.good()) {
      file.close();
      std::remove(tempPath.c_str());
      return false;
    }
  }
  if (std::rename(tempPath.c_str(), userWordListPath_.c_str()) != 0) {
    std::remove(tempPath.c_str());
    return false;
  }
  return true;
}

void LatinLexicon::reset() {
  builtinRank_.clear();
  userWords_.clear();
  sortedWords_.clear();
  builtinFileRankStarts_.clear();
  userWordListPath_.clear();
  nextBuiltinRank_ = 0;
}

bool LatinLexicon::rememberWord(const std::string& word, int weight) {
  if (word.size() < 2) {
    return true;
  }
  if (weight < 1) {
    weight = 1;
  }
  std::string lowerWord = ToLowerAscii(word);
  auto existing = userWords_.find(lowerWord);
  if (existing == userWords_.end()) {
    auto inserted = userWords_.emplace(lowerWord, weight).first;
    if (builtinRank_.find(lowerWord) == builtinRank_.end()) {
      auto position =
          std::lower_bound(sortedWords_.begin(), sortedWords_.end(), lowerWord,
                           [](const std::string* a, const std::string& b) {
                             return *a < b;
                           });
      sortedWords_.insert(position, &(inserted->first));
    }
  } else {
    existing->second += weight;
  }

  // The word (and its up-to-date count) is already live in memory either
  // way; the return value only tells the caller whether it will still be
  // there, with this count, next launch.
  return persistUserWords();
}

}  // namespace McBopomofo::MixedScript
