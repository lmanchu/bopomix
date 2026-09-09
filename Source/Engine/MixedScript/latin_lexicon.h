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
//
// LatinLexicon: a small in-memory English/Latin-script word list, used by
// MixedScriptTracker (see mixed_script_tracker.h) to tell whether a run of
// ASCII letters typed without leaving Bopomofo mode is more likely an
// English word than a Chinese reading. See
// ~/.claude/plans/zhuyin-ime-personal.md's "P1 設計" section for the
// product rationale (rules A/B/C).

#ifndef SRC_ENGINE_MIXEDSCRIPT_LATIN_LEXICON_H_
#define SRC_ENGINE_MIXEDSCRIPT_LATIN_LEXICON_H_

#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace McBopomofo::MixedScript {

// Two independent word stores are kept:
//  - the built-in list (loadBuiltinWordList()), read-only, loaded once from
//    a bundled word list file;
//  - the user list (loadUserWordList()/rememberWord()), which the user's
//    own explicit choices (Tab or candidate-window selection of a Latin
//    candidate -- see KeyHandler's mixed-script hookup) append to, so they
//    become preferred without needing a curated dictionary entry.
// isWord()/isPrefix()/rank() do not distinguish which store a hit came
// from.
//
// Not thread-safe; McBopomofo/mixime, like the rest of Source/Engine, is
// used from a single key-handling thread.
class LatinLexicon {
 public:
  LatinLexicon() = default;
  LatinLexicon(const LatinLexicon&) = delete;
  LatinLexicon& operator=(const LatinLexicon&) = delete;

  // Loads the built-in word list from `path`. Format: one lowercase ASCII
  // word per line, 2-15 characters (see tools/lexicon/build_lexicon.py for
  // the generator); a line may optionally carry a tab-separated rank
  // ("word\t123", 0 = most frequent) -- unranked lines are assigned ranks
  // in file order, after all explicitly-ranked ones. Blank lines and lines
  // starting with '#' are ignored. Merges into (does not replace) whatever
  // was already loaded, so callers can load multiple built-in files (e.g.
  // the dictionary word list and the tech-term seed list). Returns false
  // if the file cannot be opened.
  bool loadBuiltinWordList(const std::string& path);

  // Loads the user's own learned-word file (same one-word-per-line format,
  // no ranks). A missing file is not an error (expected on first run).
  bool loadUserWordList(const std::string& path);

  // Sets the path rememberWord() appends new words to. Call before the
  // first rememberWord() that should actually persist; without a path,
  // rememberWord() only affects this process's in-memory lookups.
  void setUserWordListPath(const std::string& path) {
    userWordListPath_ = path;
  }

  // Case-insensitive (ASCII-only folding; the lexicon only ever sees
  // standard-layout Latin runs). Returns true if `text` is a complete
  // dictionary entry of at least 2 characters -- see
  // MixedScriptTracker::kMinAmbiguousWordLength for why single letters
  // never count.
  bool isWord(const std::string& text) const;

  // Case-insensitive. True if some dictionary entry starts with `text`
  // (including `text` itself, and including 1-character `text`, unlike
  // isWord()). Callers can use this to decide whether it is still worth
  // continuing to treat a run as a candidate English word before it is
  // long enough for isWord() to apply. O(log n): finds `text`'s insertion
  // point in the sorted word list and checks the neighbor, rather than
  // indexing every prefix of every word up front -- the built-in list is
  // large (the full macOS system word list, see
  // tools/lexicon/build_lexicon.py), and pre-indexing all of its prefixes
  // would multiply memory use several-fold for a query pattern that is
  // not on any hot path (not currently used by MixedScriptTracker's
  // decision logic; kept for P3's predictive-typing work, see
  // zhuyin-ime-personal.md's F3 scope).
  bool isPrefix(const std::string& text) const;

  // Returns the word's rank (0 = most frequent) or -1 if `text` is not a
  // known word. User-remembered words always rank as 0 (most preferred).
  int rank(const std::string& text) const;

  size_t builtinWordCount() const { return builtinRank_.size(); }
  size_t userWordCount() const { return userWords_.size(); }

  // Records that the user explicitly accepted `word` as English (Tab-flip
  // or candidate-window pick -- never called for the automatic
  // dictionary-plus-space default, see zhuyin-ime-personal.md's P1 design
  // notes and KeyHandler's mixed-script hookup). No-op if `word` is
  // shorter than 2 characters or already known. Appends to the user word
  // list file when setUserWordListPath() has been called, and makes the
  // word available to isWord()/isPrefix()/rank() immediately either way.
  void rememberWord(const std::string& word);

 private:
  static std::string ToLowerAscii(const std::string& text);
  // Rebuilds sortedWords_ from builtinRank_ + userWords_ if either has
  // changed since the last build (see sortedWordsStale_).
  void ensureSortedWords() const;

  // word -> rank (built-in list only; 0 = most frequent).
  std::unordered_map<std::string, int> builtinRank_;
  std::unordered_set<std::string> userWords_;
  // Every known word (builtin + user), sorted lazily for isPrefix()'s
  // binary search -- rebuilding is O(n log n) over the whole list, so
  // loadBuiltinWordList()/loadUserWordList()/rememberWord() only mark this
  // stale instead of re-sorting per word (loadBuiltinWordList() alone
  // loads on the order of 10^5 words; re-sorting after every line would be
  // O(n^2)). mutable because isPrefix() is logically const.
  mutable std::vector<std::string> sortedWords_;
  mutable bool sortedWordsStale_ = true;
  std::string userWordListPath_;
  int nextBuiltinRank_ = 0;
};

}  // namespace McBopomofo::MixedScript

#endif  // SRC_ENGINE_MIXEDSCRIPT_LATIN_LEXICON_H_
