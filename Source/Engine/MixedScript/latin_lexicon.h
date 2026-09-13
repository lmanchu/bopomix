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
// Not thread-safe; McBopomofo/bopomix, like the rest of Source/Engine, is
// used from a single key-handling thread.
class LatinLexicon {
 public:
  // A user word's stored score has to reach this before it is treated as
  // "the user really means this word" -- i.e. before complete() ranks it
  // ahead of the entire built-in dictionary and sourceTier() calls it
  // confirmed. rememberWord()'s doc lists what adds how much; the point
  // is that a single passive sighting of a typed word never earns it
  // (docs/REVIEW-P3-2026-09-11.md's B2: one mistyped word used to
  // outrank the whole dictionary for its prefix, forever).
  static constexpr int kUserWordConfirmedScore = 2;
  // How much weight an *explicit* accept carries (Tab or a candidate-
  // window pick): deliberately enough to confirm a word on its own,
  // because unlike passive learn-from-typing it is an unambiguous choice
  // the user made about this exact word.
  static constexpr int kExplicitAcceptWeight = kUserWordConfirmedScore;

  // sourceTier() levels. Smaller is better.
  static constexpr int kConfirmedUserWordTier = 0;
  static constexpr int kBestSourceTier = 1;
  static constexpr int kUnrankedSourceTier = 1000;
  static constexpr int kUnknownSourceTier = -1;

  LatinLexicon() = default;
  LatinLexicon(const LatinLexicon&) = delete;
  LatinLexicon& operator=(const LatinLexicon&) = delete;

  // Loads the built-in word list from `path`. Format: one lowercase ASCII
  // word per line, 2-15 characters (see tools/lexicon/build_lexicon.py for
  // the generator); a line may optionally carry a tab-separated rank
  // ("word\t123", 0 = most frequent within *this file*) -- unranked lines
  // are assigned ranks in file order, after all explicitly-ranked ones.
  // Blank lines and lines starting with '#' are ignored. Merges into (does
  // not replace) whatever was already loaded, so callers can load
  // multiple built-in files (e.g. the tech-term seed list and the
  // dictionary word list -- see LanguageModelManager's load order).
  //
  // An explicit rank is offset by however many ranks earlier
  // loadBuiltinWordList() calls (on this same instance) already claimed,
  // so a file's "0 = most frequent" is relative to itself but the merged
  // result still has a single consistent scale: whichever file is loaded
  // *first* outranks every word in a file loaded after it, regardless of
  // the later file's own internal numbers. This is how
  // Source/Data/latin-tech-seed.txt's hand-ranked terms stay ahead of
  // every dictionary word's SCOWL-tier rank (see build_lexicon.py) without
  // a separate tier field -- rank() alone is enough for
  // LatinLexicon::complete()'s ordering.
  //
  // Returns false if the file cannot be opened.
  bool loadBuiltinWordList(const std::string& path);

  // Loads the user's own learned-word file: one word per line, optionally
  // carrying a tab-separated use count ("word\t4", see rememberWord()) --
  // a bare word (no tab) is treated as count 1, so P1-era files (written
  // before P3 added counting) still load. A missing file is not an error
  // (expected on first run).
  bool loadUserWordList(const std::string& path);

  // Discards the user store entirely and reloads it from `path`, which
  // also becomes the new setUserWordListPath(). The built-in lists are
  // left alone (they are the expensive half and do not move).
  //
  // Exists for one event: the user changing the user-phrase folder while
  // the lexicon is already loaded. Without it the in-memory user store
  // stayed the *old* folder's, and the next rememberWord() wrote those
  // words into the new folder's file (docs/REVERIFY-P3-2026-09-12.md's
  // P-1). LanguageModelManager's +reloadLatinUserWordList is the only
  // production caller, from AppDelegate's updateUserPhrases().
  void reloadUserWordList(const std::string& path);

  // Sets the path rememberWord() writes to. Call before the first
  // rememberWord() that should actually persist; without a path,
  // rememberWord() only affects this process's in-memory lookups.
  void setUserWordListPath(const std::string& path) {
    userWordListPath_ = path;
  }

  // Case-insensitive (ASCII-only folding; the lexicon only ever sees
  // standard-layout Latin runs). Returns true if `text` is a complete
  // dictionary entry of at least 2 characters -- see
  // MixedScriptTracker::kMinAmbiguousWordLength for the (longer) minimum
  // the mixed-script rules themselves apply on top of this.
  bool isWord(const std::string& text) const;

  // Case-insensitive. True only for words in the *user's own* store --
  // i.e. words this user has at some point explicitly picked as English
  // (Tab or the candidate window, via rememberWord()), never the 200k-word
  // built-in list. MixedScriptTracker::onBoundary() uses this as the sole
  // trigger for auto-committing a still-composable run as English on a
  // trailing space: the built-in list is far too permissive for that (a
  // two-letter run like "up"/"el" is both an English word and an extremely
  // common tone-1 syllable), whereas a word in this store is one the user
  // has personally disambiguated before. See zhuyin-ime-personal.md's P1
  // section and docs/REVIEW-P1-2026-09-10.md's B1/B2.
  bool isUserWord(const std::string& text) const;

  // Case-insensitive. True if some dictionary entry starts with `text`
  // (including `text` itself, and including 1-character `text`, unlike
  // isWord()). Callers can use this to decide whether it is still worth
  // continuing to treat a run as a candidate English word before it is
  // long enough for isWord() to apply. O(log n) on *every* call, including
  // the first: sortedWords_ is kept in order as the lists load (the
  // bundled files are emitted pre-sorted by tools/lexicon/build_lexicon.py,
  // so keeping it ordered is a linear merge, not a sort) rather than being
  // sorted lazily on first use, which used to cost ~294 ms on the key
  // thread the first time anything called this. Not on P1's hot path
  // (MixedScriptTracker's decision logic never calls it); kept for P3's
  // predictive-typing work, see zhuyin-ime-personal.md's F3 scope.
  bool isPrefix(const std::string& text) const;

  // Returns the word's rank (0 = most frequent) or -1 if `text` is not a
  // known word. User-remembered words always rank as 0 (most preferred).
  int rank(const std::string& text) const;

  // P3 (docs/REVIEW-P3-2026-09-11.md's B3). How good this word's *source*
  // is, coarsely -- smaller is better:
  //
  //   kConfirmedUserWordTier (0) a confirmed user word (score >=
  //                              kUserWordConfirmedScore)
  //   kBestSourceTier        (1) the first built-in file loaded (the
  //                              hand-ranked tech seed, whose internal
  //                              0..n order is a preference between seed
  //                              terms, not a frequency measurement) AND
  //                              the dictionary's most frequent tier
  //   kBestSourceTier + t        SCOWL tier t of the dictionary file
  //   kUnrankedSourceTier        a user word with no dictionary entry and
  //                              no confirmation yet
  //   kUnknownSourceTier    (-1) not a known word at all
  //
  // "The first built-in file loaded is the seed list" is the same load-
  // order convention loadBuiltinWordList()'s rank-offset doc already
  // relies on. With only one built-in file loaded (tests, or a build
  // whose seed resource is missing) every built-in word therefore lands
  // on kBestSourceTier, which makes the callers' "already a finished
  // word" gate maximally conservative rather than wrong.
  //
  // Unlike rank(), this is comparable *across* files, which is the whole
  // point: rank() puts every seed term ahead of every dictionary word, so
  // comparing raw ranks made a finished ordinary word like "code" look
  // worse than the seed term "codesign" that merely extends it, and Tab
  // rewrote the one into the other (B3). The seed file deliberately ties
  // with dictionary tier 0 rather than beating it so that a completed
  // common word is never grown into a product term; a *rarer* word (a
  // higher tier) can still be grown, which is what keeps prefixes like
  // "th" completing normally.
  int sourceTier(const std::string& text) const;

  // P3 predictive typing (see zhuyin-ime-personal.md's F3 scope). Returns
  // up to `n` known words that start with (but are longer than) `prefix`,
  // best completion first. Ordering: a *confirmed* user word (score >=
  // kUserWordConfirmedScore) beats every builtin word, ranked among
  // themselves by score (highest first); a word the dictionary knows is
  // ranked by rank() no matter what the user store says about it (which
  // is why one passive sighting promotes nothing), and anything still
  // tied breaks alphabetically.
  //
  // An *unconfirmed* user word the dictionary does not know is not
  // returned at all -- not last, not at all. That is the disk half of
  // the learn-from-typing staging policy (see rememberWord()): a word
  // nothing but a single typed run vouches for is written down so the
  // evidence survives a relaunch, but it is not a suggestion yet, and a
  // suggestion the user never asked for is exactly the failure
  // docs/REVIEW-P3-2026-09-11.md's B2 was about.
  //
  // O(k log n) where k is the number of matching words in the dictionary,
  // not the dictionary's total size: uses sortedWords_'s existing binary
  // search to find the matching range, then keeps only a size-n heap of
  // the best candidates seen (front() = the worst of them, the one an
  // incoming candidate must beat) rather than sorting the whole range.
  std::vector<std::string> complete(const std::string& prefix, size_t n) const;

  size_t builtinWordCount() const { return builtinRank_.size(); }
  size_t userWordCount() const { return userWords_.size(); }

  // Records that the user accepted `word` as English -- a P1
  // mixedScript Tab/candidate-window pick (see KeyHandler's
  // fixNodeWithReading:) or a P3 completion accept (Tab or the completion
  // candidate window, see KeyHandler's _handleTabState) -- and adds
  // `weight` to its stored score, creating the word at `weight` if this
  // is the first time. Pass kExplicitAcceptWeight for a deliberate
  // accept (which confirms the word on its own) and 1 for one passive
  // learn-from-typing sighting; see kUserWordConfirmedScore for what
  // "confirmed" then buys -- and complete()'s doc for why a word only
  // *this* store knows about stays out of the suggestions until it is
  // confirmed. No-op if `word` is shorter than 2 characters.
  //
  // Rewrites the whole user word list file (not an append) when
  // setUserWordListPath() has been called, since an existing word's count
  // has to change in place; the user list is small (tens to hundreds of
  // entries, never the 200k-word builtin list) so this is cheap. The
  // rewrite merges with whatever is on disk rather than overwriting it,
  // and lands through a temp file plus rename -- see persistUserWords().
  // Makes the word (and its new count) available to
  // isWord()/isUserWord()/isPrefix()/rank()/complete() immediately either
  // way.
  //
  // Returns false only when the in-memory update succeeded but persisting
  // it did not (the file could not be opened or the write failed) -- the
  // caller is expected to log that and carry on, since typing must never
  // be blocked by a word-list write. Returns true when there was nothing
  // to do or everything succeeded.
  bool rememberWord(const std::string& word, int weight = 1);

  // Testing-only: discards every loaded word (builtin and user) and all
  // rank bookkeeping, returning the object to its just-constructed state.
  // The only production caller is LanguageModelManager's
  // resetLatinLexiconForTesting(), added to fix
  // docs/REVERIFY-P1-2026-09-10.md's R12 (every XCTest KeyHandler-level
  // test target shares one process-wide LatinLexicon, so an explicit
  // Tab/candidate pick in one test silently changed another test's "top
  // completion" ranking whenever both ran in the same process) --
  // ordinary operation never needs to un-load a word list.
  void reset();

 private:
  static std::string ToLowerAscii(const std::string& text);
  // Merges the pointers appended to sortedWords_ since `oldSize` into the
  // already-ordered prefix in front of them.
  void mergeNewSortedWords(size_t oldSize);
  // sourceTier()'s builtin half: maps a merged rank back to the file it
  // came from and that file's own in-file rank.
  int builtinTierForRank(int wordRank) const;
  // Rewrites userWordListPath_ from userWords_ *merged with whatever the
  // file currently holds* (per word, the larger of the two counts wins),
  // through a sibling temp file that is then renamed over the target.
  //
  // Both halves of that exist for docs/REVERIFY-P3-2026-09-12.md's P-1.
  // The old implementation truncated the target and dumped userWords_
  // over it, which meant the file this process had never read -- the new
  // folder's, right after the user moved the user-phrase location, or a
  // copy another machine had added to over Dropbox -- lost every word it
  // held. Merging makes the write additive; the rename makes it
  // all-or-nothing.
  //
  // Returns true if there is no path to write to (nothing to do, not a
  // failure) or the write succeeded.
  bool persistUserWords() const;

  // word -> rank (built-in list only; 0 = most frequent).
  std::unordered_map<std::string, int> builtinRank_;
  // word -> score (what rememberWord() has accumulated for this word; see
  // its doc for what adds how much, and complete()'s for why this exists
  // alongside rank()/isUserWord()'s simpler boolean view of this store).
  std::unordered_map<std::string, int> userWords_;
  // The merged-rank value each loadBuiltinWordList() call started at, in
  // load order -- sourceTier()'s only way back from a merged rank to the
  // file's own tier numbering.
  std::vector<int> builtinFileRankStarts_;
  // Every known word (builtin + user), kept sorted for isPrefix()/
  // complete()'s binary search. These point at the keys stored inside
  // builtinRank_/userWords_, which std::unordered_map guarantees stay at
  // a fixed address for as long as the element lives (rehashing
  // invalidates iterators, not references) -- so this costs one pointer
  // per word rather than a second copy of the whole 200k-word list. Kept
  // ordered as words arrive (see mergeNewSortedWords) instead of being
  // sorted lazily on the first isPrefix(), which used to stall the key
  // thread.
  std::vector<const std::string*> sortedWords_;
  std::string userWordListPath_;
  int nextBuiltinRank_ = 0;
};

}  // namespace McBopomofo::MixedScript

#endif  // SRC_ENGINE_MIXEDSCRIPT_LATIN_LEXICON_H_
