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
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <utility>

#include "gtest/gtest.h"

namespace McBopomofo::MixedScript {

namespace {

// Writes `content` to a fresh temp file and returns its path; the file is
// removed when the returned guard goes out of scope.
class TempFile {
 public:
  explicit TempFile(const std::string& content) {
    path_ = std::filesystem::temp_directory_path() /
            ("bopomix_latin_lexicon_test_" +
             std::to_string(reinterpret_cast<uintptr_t>(this)) + ".txt");
    std::ofstream file(path_);
    file << content;
  }
  ~TempFile() { std::filesystem::remove(path_); }
  const std::string path() const { return path_.string(); }

 private:
  std::filesystem::path path_;
};

}  // namespace

TEST(LatinLexiconTest, LoadsBuiltinWordsCaseInsensitively) {
  TempFile file("acer\napi\nchat\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  EXPECT_TRUE(lexicon.isWord("acer"));
  EXPECT_TRUE(lexicon.isWord("ACER"));
  EXPECT_TRUE(lexicon.isWord("Api"));
  EXPECT_FALSE(lexicon.isWord("apix"));
}

TEST(LatinLexiconTest, RejectsSingleLetterWords) {
  TempFile file("a\ni\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  // isWord() requires >= 2 characters (see MixedScriptTracker's
  // kMinAmbiguousWordLength doc for why); isPrefix() has no such floor.
  EXPECT_FALSE(lexicon.isWord("a"));
  EXPECT_TRUE(lexicon.isPrefix("a"));
}

TEST(LatinLexiconTest, IsPrefixMatchesAnyLength) {
  TempFile file("acer\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  EXPECT_TRUE(lexicon.isPrefix("a"));
  EXPECT_TRUE(lexicon.isPrefix("ac"));
  EXPECT_TRUE(lexicon.isPrefix("acer"));
  EXPECT_FALSE(lexicon.isPrefix("acerx"));
  EXPECT_FALSE(lexicon.isPrefix("z"));
}

TEST(LatinLexiconTest, RankPrefersLowerNumberAndExplicitRank) {
  TempFile file("common\t0\nrare\t500\nunranked\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  EXPECT_EQ(lexicon.rank("common"), 0);
  EXPECT_EQ(lexicon.rank("rare"), 500);
  EXPECT_GE(lexicon.rank("unranked"), 0);
  EXPECT_EQ(lexicon.rank("nonexistent"), -1);
}

TEST(LatinLexiconTest, MissingBuiltinFileReturnsFalse) {
  LatinLexicon lexicon;
  EXPECT_FALSE(lexicon.loadBuiltinWordList("/nonexistent/path/does-not-exist.txt"));
  EXPECT_EQ(lexicon.builtinWordCount(), 0u);
}

TEST(LatinLexiconTest, MissingUserFileIsNotAnError) {
  LatinLexicon lexicon;
  EXPECT_FALSE(lexicon.loadUserWordList("/nonexistent/path/does-not-exist.txt"));
  EXPECT_EQ(lexicon.userWordCount(), 0u);
}

TEST(LatinLexiconTest, RememberWordIsImmediatelyVisible) {
  LatinLexicon lexicon;
  EXPECT_FALSE(lexicon.isWord("openrouter"));
  lexicon.rememberWord("OpenRouter");
  EXPECT_TRUE(lexicon.isWord("openrouter"));
  EXPECT_TRUE(lexicon.isWord("OpenRouter"));
  EXPECT_EQ(lexicon.rank("openrouter"), 0);
}

TEST(LatinLexiconTest, RememberWordPersistsToUserFile) {
  std::filesystem::path userPath =
      std::filesystem::temp_directory_path() /
      "bopomix_latin_lexicon_test_user_words.txt";
  std::filesystem::remove(userPath);

  {
    LatinLexicon lexicon;
    lexicon.setUserWordListPath(userPath.string());
    lexicon.rememberWord("agent");
  }

  LatinLexicon reloaded;
  ASSERT_TRUE(reloaded.loadUserWordList(userPath.string()));
  EXPECT_TRUE(reloaded.isWord("agent"));

  std::filesystem::remove(userPath);
}

TEST(LatinLexiconTest, RememberWordSkipsSingleLetters) {
  LatinLexicon lexicon;
  lexicon.rememberWord("a");
  EXPECT_EQ(lexicon.userWordCount(), 0u);
}

// isUserWord() is what decides whether a trailing space auto-commits a
// still-composable run as English, so it must never be true for a word
// that only came from the bundled list.
TEST(LatinLexiconTest, IsUserWordSeparatesTheTwoStores) {
  TempFile file("acer\napi\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));
  lexicon.rememberWord("openrouter");

  EXPECT_TRUE(lexicon.isWord("acer"));
  EXPECT_FALSE(lexicon.isUserWord("acer"));
  EXPECT_TRUE(lexicon.isWord("openrouter"));
  EXPECT_TRUE(lexicon.isUserWord("OpenRouter"));
  EXPECT_FALSE(lexicon.isUserWord(""));
  EXPECT_FALSE(lexicon.isUserWord("nonexistent"));
}

TEST(LatinLexiconTest, LoadUserWordListCountsAsUserWords) {
  TempFile file("openrouter\ngmail\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadUserWordList(file.path()));

  EXPECT_TRUE(lexicon.isUserWord("gmail"));
  EXPECT_TRUE(lexicon.isWord("gmail"));
  EXPECT_EQ(lexicon.userWordCount(), 2u);
}

// isPrefix() has to work across every store and every load, without the
// lazy whole-list sort it used to do on first call.
TEST(LatinLexiconTest, IsPrefixSpansMultipleLoadsAndRememberedWords) {
  TempFile builtin("acer\napi\nzebra\n");
  TempFile seed("gmail\nopenrouter\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(builtin.path()));
  ASSERT_TRUE(lexicon.loadBuiltinWordList(seed.path()));
  lexicon.rememberWord("mixime");

  EXPECT_TRUE(lexicon.isPrefix("ac"));
  EXPECT_TRUE(lexicon.isPrefix("gm"));
  EXPECT_TRUE(lexicon.isPrefix("openr"));
  EXPECT_TRUE(lexicon.isPrefix("mix"));
  EXPECT_TRUE(lexicon.isPrefix("z"));
  EXPECT_FALSE(lexicon.isPrefix("qq"));
  EXPECT_FALSE(lexicon.isPrefix("mixz"));
}

// A word that arrives from both stores must not be double-counted in the
// sorted list backing isPrefix().
TEST(LatinLexiconTest, DuplicateAcrossStoresStaysConsistent) {
  TempFile builtin("acer\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(builtin.path()));
  lexicon.rememberWord("acer");

  EXPECT_TRUE(lexicon.isWord("acer"));
  EXPECT_TRUE(lexicon.isUserWord("acer"));
  EXPECT_TRUE(lexicon.isPrefix("ace"));
}

TEST(LatinLexiconTest, RememberWordReportsAFailedWrite) {
  LatinLexicon lexicon;
  // A path whose parent does not exist: the word still becomes usable
  // this session, the caller is just told it will not persist.
  lexicon.setUserWordListPath("/nonexistent/path/latin-user.txt");
  EXPECT_FALSE(lexicon.rememberWord("openrouter"));
  EXPECT_TRUE(lexicon.isUserWord("openrouter"));
}

TEST(LatinLexiconTest, RememberWordReportsSuccessWhenItPersists) {
  std::filesystem::path userPath =
      std::filesystem::temp_directory_path() /
      "bopomix_latin_lexicon_test_remember_ok.txt";
  std::filesystem::remove(userPath);

  LatinLexicon lexicon;
  lexicon.setUserWordListPath(userPath.string());
  EXPECT_TRUE(lexicon.rememberWord("openrouter"));
  // Already known: nothing to do, still a success.
  EXPECT_TRUE(lexicon.rememberWord("openrouter"));
  // Too short to record at all.
  EXPECT_TRUE(lexicon.rememberWord("a"));

  std::filesystem::remove(userPath);
}

// P3: rememberWord() now counts uses (see LatinLexicon::complete()'s
// ordering), not just first-time membership.
TEST(LatinLexiconTest, RememberWordCountsRepeatedAcceptances) {
  LatinLexicon lexicon;
  lexicon.rememberWord("acer");
  lexicon.rememberWord("acer");
  lexicon.rememberWord("acer");

  // rank() only ever reports "0 = user word", not the count -- complete()
  // is what actually reads the count (see the ordering tests below).
  EXPECT_EQ(lexicon.rank("acer"), 0);
}

// A bare word (no tab) is a P1-era file and must still load as count 1;
// a tab-counted line is the P3 format. The parsed count actually affects
// ordering (not just membership), verified via complete().
TEST(LatinLexiconTest, LoadUserWordListAcceptsBothPreAndPostP3Formats) {
  // Both words are in the dictionary too, so the *only* thing that can
  // order them is the parsed user count (an unconfirmed user word the
  // dictionary does not know is not offered at all -- see
  // CompleteOmitsAnUnconfirmedUnknownUserWord).
  TempFile builtin("worklegacy\t0\nworknew\t1\n");
  TempFile file("worklegacy\nworknew\t7\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(builtin.path()));
  ASSERT_TRUE(lexicon.loadUserWordList(file.path()));

  EXPECT_TRUE(lexicon.isUserWord("worklegacy"));
  EXPECT_TRUE(lexicon.isUserWord("worknew"));
  EXPECT_EQ(lexicon.userWordCount(), 2u);

  // "worknew" (parsed count 7, confirmed) outranks the whole dictionary;
  // "worklegacy" (parsed count 1) does not, and falls back to its builtin
  // rank -- which is the *better* of the two, so this ordering is only
  // possible if the tab-count really round-tripped through the load.
  std::vector<std::string> completions = lexicon.complete("work", 10);
  ASSERT_EQ(completions.size(), 2u);
  EXPECT_EQ(completions[0], "worknew");
  EXPECT_EQ(completions[1], "worklegacy");
}

TEST(LatinLexiconTest, RememberWordRewritesExistingCountInPlace) {
  std::filesystem::path userPath =
      std::filesystem::temp_directory_path() /
      "bopomix_latin_lexicon_test_rewrite_count.txt";
  std::filesystem::remove(userPath);

  {
    LatinLexicon lexicon;
    lexicon.setUserWordListPath(userPath.string());
    lexicon.rememberWord("agent");
    lexicon.rememberWord("agent");
    lexicon.rememberWord("agent");
  }

  LatinLexicon reloaded;
  ASSERT_TRUE(reloaded.loadUserWordList(userPath.string()));
  EXPECT_TRUE(reloaded.isUserWord("agent"));
  // Exactly one line for "agent" (a naive append-only implementation would
  // have written it three times).
  std::ifstream in(userPath);
  std::string line;
  int agentLines = 0;
  while (std::getline(in, line)) {
    if (line.rfind("agent\t", 0) == 0) {
      ++agentLines;
      EXPECT_EQ(line, "agent\t3");
    }
  }
  EXPECT_EQ(agentLines, 1);

  std::filesystem::remove(userPath);
}

// docs/REVERIFY-P3-2026-09-12.md's P-1, half one: the file being written
// is not necessarily the file this process loaded. Another machine adding
// words over Dropbox, or the user pointing the folder somewhere that
// already has a list, used to be answered by truncating the target and
// dumping this process's memory over it.
TEST(LatinLexiconTest, PersistMergesWithWhateverIsOnDiskInsteadOfOverwriting) {
  std::filesystem::path userPath =
      std::filesystem::temp_directory_path() /
      "bopomix_latin_lexicon_test_persist_merge.txt";
  std::filesystem::remove(userPath);

  LatinLexicon lexicon;
  lexicon.setUserWordListPath(userPath.string());
  lexicon.rememberWord("localword", LatinLexicon::kExplicitAcceptWeight);

  // Somebody else (another machine, a hand edit) rewrites the file while
  // this process is running: one word it has never heard of, and a higher
  // count for one it has.
  {
    std::ofstream out(userPath, std::ios::trunc);
    out << "remoteword\t9\n"
        << "localword\t5\n";
  }

  ASSERT_TRUE(lexicon.rememberWord("localword"));

  LatinLexicon reloaded;
  ASSERT_TRUE(reloaded.loadUserWordList(userPath.string()));
  EXPECT_TRUE(reloaded.isUserWord("remoteword"))
      << "a word only the file knew about must survive the write";
  EXPECT_TRUE(reloaded.isUserWord("localword"));
  EXPECT_EQ(reloaded.userWordCount(), 2u);

  // Per word the larger count wins: the file said 5, memory said 3.
  std::ifstream in(userPath);
  std::string line;
  bool sawLocalAtFive = false;
  while (std::getline(in, line)) {
    if (line.rfind("localword\t", 0) == 0) {
      EXPECT_EQ(line, "localword\t5");
      sawLocalAtFive = true;
    }
  }
  EXPECT_TRUE(sawLocalAtFive);

  std::filesystem::remove(userPath);
}

// The same fix seen through the gesture that caused it: the user moves
// the user-phrase folder to one that already holds a word list.
TEST(LatinLexiconTest, WritingAfterAFolderChangeDoesNotClobberTheNewFolder) {
  std::filesystem::path folderA =
      std::filesystem::temp_directory_path() / "bopomix_lexicon_folder_a";
  std::filesystem::path folderB =
      std::filesystem::temp_directory_path() / "bopomix_lexicon_folder_b";
  std::filesystem::remove_all(folderA);
  std::filesystem::remove_all(folderB);
  std::filesystem::create_directories(folderA);
  std::filesystem::create_directories(folderB);
  std::filesystem::path pathA = folderA / "latin-user.txt";
  std::filesystem::path pathB = folderB / "latin-user.txt";
  {
    std::ofstream out(pathB);
    out << "dropboxword\t4\n";
  }

  LatinLexicon lexicon;
  lexicon.setUserWordListPath(pathA.string());
  lexicon.rememberWord("folderaword", LatinLexicon::kExplicitAcceptWeight);

  // Folder changed. reloadUserWordList() is what AppDelegate's
  // updateUserPhrases() now triggers; the old folder's words leave memory
  // and the new folder's arrive.
  lexicon.reloadUserWordList(pathB.string());
  EXPECT_FALSE(lexicon.isUserWord("folderaword"))
      << "the old folder's words must not follow the user to the new one";
  EXPECT_TRUE(lexicon.isUserWord("dropboxword"));

  ASSERT_TRUE(lexicon.rememberWord("newfolderword",
                                   LatinLexicon::kExplicitAcceptWeight));

  LatinLexicon inB;
  ASSERT_TRUE(inB.loadUserWordList(pathB.string()));
  EXPECT_TRUE(inB.isUserWord("dropboxword")) << "B's own list must survive";
  EXPECT_TRUE(inB.isUserWord("newfolderword"));
  EXPECT_FALSE(inB.isUserWord("folderaword"));
  EXPECT_EQ(inB.userWordCount(), 2u);

  LatinLexicon inA;
  ASSERT_TRUE(inA.loadUserWordList(pathA.string()));
  EXPECT_TRUE(inA.isUserWord("folderaword"));
  EXPECT_EQ(inA.userWordCount(), 1u) << "the old folder must not be touched";

  std::filesystem::remove_all(folderA);
  std::filesystem::remove_all(folderB);
}

// reloadUserWordList() rebuilds sortedWords_, which holds raw pointers
// into the very map it clears. Checking the binary searches afterwards is
// how a dangling pointer would show up as something other than a crash.
TEST(LatinLexiconTest, ReloadUserWordListKeepsTheSortedIndexConsistent) {
  TempFile builtin("thing\t0\nthink\t1\n");
  TempFile first("aardvarkone\t3\nthink\t3\n");
  TempFile second("zebratwo\t3\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(builtin.path()));
  ASSERT_TRUE(lexicon.loadUserWordList(first.path()));
  ASSERT_EQ(lexicon.complete("thin", 1), std::vector<std::string> { "think" });

  lexicon.reloadUserWordList(second.path());

  EXPECT_FALSE(lexicon.isUserWord("aardvarkone"));
  EXPECT_FALSE(lexicon.isPrefix("aardvark"));
  EXPECT_TRUE(lexicon.isUserWord("zebratwo"));
  EXPECT_TRUE(lexicon.isPrefix("zebra"));
  // "think" was in both stores; its builtin half must be untouched, and
  // with the user store's confirmation gone it drops back behind "thing".
  EXPECT_TRUE(lexicon.isWord("think"));
  EXPECT_FALSE(lexicon.isUserWord("think"));
  EXPECT_EQ(lexicon.complete("thin", 1), std::vector<std::string> { "thing" });
  EXPECT_EQ(lexicon.builtinWordCount(), 2u);
  EXPECT_EQ(lexicon.userWordCount(), 1u);
}

// Testing-only reset(), added to fix docs/REVERIFY-P1-2026-09-10.md's R12
// (LanguageModelManager's gLatinLexicon is a process-wide global every
// XCTest KeyHandler-level test target shares -- see
// resetLatinLexiconForTesting()). Must undo everything loadBuiltinWordList()/
// loadUserWordList()/rememberWord() can accumulate.
TEST(LatinLexiconTest, ResetClearsBuiltinAndUserWordsAndRankBookkeeping) {
  TempFile builtin("acer\tzero\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(builtin.path()));
  lexicon.rememberWord("openrouter");
  ASSERT_TRUE(lexicon.isWord("acer"));
  ASSERT_TRUE(lexicon.isUserWord("openrouter"));

  lexicon.reset();

  EXPECT_FALSE(lexicon.isWord("acer"));
  EXPECT_FALSE(lexicon.isUserWord("openrouter"));
  EXPECT_EQ(lexicon.builtinWordCount(), 0u);
  EXPECT_EQ(lexicon.userWordCount(), 0u);
  EXPECT_FALSE(lexicon.isPrefix("ac"));
  EXPECT_EQ(lexicon.rank("acer"), -1);

  // The instance is fully reusable afterward, including rank bookkeeping
  // starting over from 0 rather than continuing from where it left off.
  TempFile builtin2("fresh\n");
  ASSERT_TRUE(lexicon.loadBuiltinWordList(builtin2.path()));
  EXPECT_EQ(lexicon.rank("fresh"), 0);
}

// setUserWordListPath() is part of the state reset() must clear too, or a
// reset lexicon would keep writing rememberWord() calls to a path from a
// previous test's now-deleted temp folder until the next explicit
// setUserWordListPath() call.
TEST(LatinLexiconTest, ResetClearsUserWordListPath) {
  std::filesystem::path userPath =
      std::filesystem::temp_directory_path() /
      "bopomix_latin_lexicon_test_reset_path.txt";
  std::filesystem::remove(userPath);

  LatinLexicon lexicon;
  lexicon.setUserWordListPath(userPath.string());
  lexicon.reset();
  EXPECT_TRUE(lexicon.rememberWord("openrouter"));
  // persistUserWords() treats an empty path as "nothing to do", so the
  // file must not have been created by the rememberWord() call above.
  EXPECT_FALSE(std::filesystem::exists(userPath));
}

// --- complete() ---

TEST(LatinLexiconTest, CompleteReturnsLongerWordsOnly) {
  TempFile file("acer\nacerbate\nacerbic\nace\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  std::vector<std::string> completions = lexicon.complete("acer", 10);
  ASSERT_EQ(completions.size(), 2u);
  for (const auto& word : completions) {
    EXPECT_NE(word, "acer");  // The prefix itself is excluded.
  }
}

TEST(LatinLexiconTest, CompleteRespectsRankWithinBuiltinTier) {
  TempFile file("common\t0\nrarer\t5\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  std::vector<std::string> completions = lexicon.complete("co", 10);
  ASSERT_EQ(completions.size(), 1u);
  EXPECT_EQ(completions[0], "common");

  completions = lexicon.complete("ra", 10);
  ASSERT_EQ(completions.size(), 1u);
  EXPECT_EQ(completions[0], "rarer");
}

TEST(LatinLexiconTest, CompleteOrdersByTierThenRankThenAlphabetical) {
  // "co" prefixes: a builtin word at two different ranks, plus a
  // never-picked builtin word tied with one of them alphabetically.
  TempFile file("cot\t3\ncow\t3\ncomet\t1\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));
  // The user has picked "cow" before (twice) but never "cot" or "comet".
  lexicon.rememberWord("cow");
  lexicon.rememberWord("cow");

  std::vector<std::string> completions = lexicon.complete("co", 10);
  ASSERT_EQ(completions.size(), 3u);
  // Tier 0 (user lexicon) beats tier 1 (builtin) regardless of rank.
  EXPECT_EQ(completions[0], "cow");
  // Within tier 1, lower rank (comet=1) beats higher rank (cot=3).
  EXPECT_EQ(completions[1], "comet");
  EXPECT_EQ(completions[2], "cot");
}

TEST(LatinLexiconTest, CompleteOrdersUserWordsByCountDescending) {
  LatinLexicon lexicon;
  lexicon.rememberWord("apple");
  lexicon.rememberWord("apple");
  lexicon.rememberWord("apple");
  lexicon.rememberWord("apply");
  lexicon.rememberWord("apply");
  // Confirmed in one call, the way an explicit Tab/candidate accept does.
  lexicon.rememberWord("appstore", LatinLexicon::kExplicitAcceptWeight);

  std::vector<std::string> completions = lexicon.complete("app", 10);
  ASSERT_EQ(completions.size(), 3u);
  EXPECT_EQ(completions[0], "apple");     // score 3
  EXPECT_EQ(completions[1], "apply");     // score 2
  EXPECT_EQ(completions[2], "appstore");  // score 2, loses the tie on spelling
}

// docs/REVIEW-P3-2026-09-11.md's B2: a word with only a single passive
// learn-from-typing sighting behind it must NOT leapfrog the dictionary.
// Before this, every user word was tier 0 no matter how it got there, so
// one mistyped word owned its prefix permanently.
TEST(LatinLexiconTest, CompleteKeepsAnUnconfirmedUserWordBehindTheDictionary) {
  TempFile file("thing\t0\nthink\t1\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));
  lexicon.rememberWord("think");  // One sighting only: score 1.

  EXPECT_EQ(lexicon.complete("thin", 1), std::vector<std::string> { "thing" });

  // A second sighting confirms it and it takes over.
  lexicon.rememberWord("think");
  EXPECT_EQ(lexicon.complete("thin", 1), std::vector<std::string> { "think" });
}

// A user word the dictionary has never heard of and that is still
// unconfirmed -- one typed sighting staged on disk, a hand-edited line, or
// a pre-P3 latin-user.txt -- is left out of the suggestions entirely, not
// merely sorted last. See complete()'s doc.
TEST(LatinLexiconTest, CompleteOmitsAnUnconfirmedUnknownUserWord) {
  TempFile file("thing\t0\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));
  TempFile userFile("thqrst\t1\n");
  ASSERT_TRUE(lexicon.loadUserWordList(userFile.path()));

  EXPECT_EQ(lexicon.complete("th", 10), std::vector<std::string> { "thing" });
  EXPECT_TRUE(lexicon.complete("thq", 10).empty());
  // It is still a known word for every other purpose -- this is only
  // about what gets suggested.
  EXPECT_TRUE(lexicon.isWord("thqrst"));
  EXPECT_TRUE(lexicon.isPrefix("thqr"));
}

// docs/REVIEW-P3-2026-09-11.md's B1. The bug only showed up once the
// candidate set was larger than n AND the good candidates were scanned
// *after* the heap filled up -- exactly the shape every existing ordering
// test lacked (each had 3 candidates and asked for 10, so the eviction
// branch never ran at all). Scan order is alphabetical, so putting the
// best-ranked words last alphabetically is what makes this adversarial:
// with the old comparator the answer was "the alphabetically first n,
// with one slot churning", i.e. thaa/thab here.
TEST(LatinLexiconTest, CompleteKeepsTheBestCandidatesWhenMoreMatchThanFit) {
  TempFile file(
      "thaa\t9\nthab\t9\nthac\t9\nthad\t9\nthae\t9\n"
      "thza\t1\nthzb\t2\nthzc\t3\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  std::vector<std::string> completions = lexicon.complete("th", 3);
  ASSERT_EQ(completions.size(), 3u);
  EXPECT_EQ(completions[0], "thza");  // rank 1
  EXPECT_EQ(completions[1], "thzb");  // rank 2
  EXPECT_EQ(completions[2], "thzc");  // rank 3
}

// The same property, stated generally and checked against the obvious
// slow implementation: for every prefix and every n, complete(prefix, n)
// must equal the first n entries of a full sort of all matches. A
// hand-written example can be satisfied by a comparator that is wrong in
// some other direction; this cannot.
TEST(LatinLexiconTest, CompleteMatchesAFullSortForEveryPrefixAndN) {
  std::mt19937 rng(1234);
  std::uniform_int_distribution<int> rankDist(0, 4);
  std::vector<std::pair<std::string, int>> words;
  std::string content;
  for (char a = 'a'; a <= 'e'; ++a) {
    for (char b = 'a'; b <= 'e'; ++b) {
      for (char c = 'a'; c <= 'e'; ++c) {
        std::string word { a, b, c };
        int rank = rankDist(rng);
        words.emplace_back(word, rank);
        content += word + "\t" + std::to_string(rank) + "\n";
      }
    }
  }
  TempFile file(content);
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));
  // A couple of confirmed user words so tier 0 participates too.
  lexicon.rememberWord("abc", LatinLexicon::kExplicitAcceptWeight);
  lexicon.rememberWord("bcd", LatinLexicon::kExplicitAcceptWeight);

  for (char a = 'a'; a <= 'e'; ++a) {
    for (char b = 'a'; b <= 'e'; ++b) {
      std::string prefix { a, b };
      // The reference answer: every strictly-longer match, fully sorted
      // by the documented ordering.
      std::vector<std::pair<std::string, int>> matches;
      for (const auto& entry : words) {
        if (entry.first.size() > prefix.size() &&
            entry.first.compare(0, prefix.size(), prefix) == 0) {
          matches.push_back(entry);
        }
      }
      std::sort(matches.begin(), matches.end(),
                [&lexicon](const auto& x, const auto& y) {
                  bool xUser = lexicon.isUserWord(x.first);
                  bool yUser = lexicon.isUserWord(y.first);
                  if (xUser != yUser) {
                    return xUser;
                  }
                  if (!xUser && x.second != y.second) {
                    return x.second < y.second;
                  }
                  return x.first < y.first;
                });

      for (size_t n = 1; n <= matches.size(); ++n) {
        std::vector<std::string> expected;
        for (size_t i = 0; i < n; ++i) {
          expected.push_back(matches[i].first);
        }
        EXPECT_EQ(lexicon.complete(prefix, n), expected)
            << "prefix=" << prefix << " n=" << n;
      }
    }
  }
}

// docs/REVIEW-P3-2026-09-11.md's B3. sourceTier() is the cross-file
// comparison rank() cannot express: the hand-ranked seed file ties with
// the dictionary's most frequent tier instead of beating it, so a
// finished ordinary word is never "worse" than a seed term that merely
// extends it.
TEST(LatinLexiconTest, SourceTierTiesTheSeedFileWithTheDictionarysBestTier) {
  TempFile techSeed("codesign\t0\nacer\t4\n");
  TempFile dictionary("code\t0\ncodex\t3\nacerbic\t1\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(techSeed.path()));
  ASSERT_TRUE(lexicon.loadBuiltinWordList(dictionary.path()));

  // rank() still puts the whole seed file first -- that is what makes it
  // win completions.
  EXPECT_LT(lexicon.rank("codesign"), lexicon.rank("code"));
  // sourceTier() does not: seed and dictionary-tier-0 are the same level.
  EXPECT_EQ(lexicon.sourceTier("codesign"), LatinLexicon::kBestSourceTier);
  EXPECT_EQ(lexicon.sourceTier("code"), LatinLexicon::kBestSourceTier);
  // Deeper dictionary tiers are worse, by exactly the tier number.
  EXPECT_EQ(lexicon.sourceTier("codex"), LatinLexicon::kBestSourceTier + 3);
  EXPECT_EQ(lexicon.sourceTier("acerbic"), LatinLexicon::kBestSourceTier + 1);
  // A seed word's own in-file rank does not make it a worse source.
  EXPECT_EQ(lexicon.sourceTier("acer"), LatinLexicon::kBestSourceTier);
  // Not a word at all.
  EXPECT_EQ(lexicon.sourceTier("aweso"), LatinLexicon::kUnknownSourceTier);
}

TEST(LatinLexiconTest, SourceTierPromotesOnlyConfirmedUserWords) {
  // Two files, matching production's seed-then-dictionary load order --
  // sourceTier() reads the *second* file's in-file rank as the tier (see
  // its doc).
  TempFile techSeed("codesign\t0\n");
  TempFile dictionary("thing\t2\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(techSeed.path()));
  ASSERT_TRUE(lexicon.loadBuiltinWordList(dictionary.path()));

  lexicon.rememberWord("thing");
  EXPECT_EQ(lexicon.sourceTier("thing"), LatinLexicon::kBestSourceTier + 2)
      << "one sighting must not change where the word came from";
  lexicon.rememberWord("thing");
  EXPECT_EQ(lexicon.sourceTier("thing"), LatinLexicon::kConfirmedUserWordTier);

  // An unconfirmed user word the dictionary does not know has no
  // frequency evidence at all.
  TempFile userFile("thqrst\t1\n");
  ASSERT_TRUE(lexicon.loadUserWordList(userFile.path()));
  EXPECT_EQ(lexicon.sourceTier("thqrst"), LatinLexicon::kUnrankedSourceTier);
}

// docs/REVIEW-P3-2026-09-11.md's B2, staged on disk instead of in memory
// (docs/REVERIFY-P3-2026-09-12.md's "pending 落地"): the first sighting of
// a word the dictionary does not know is written down -- so the evidence
// survives a relaunch, which the old in-memory staging never did -- but it
// is not a suggestion until a second sighting confirms it.
TEST(LatinLexiconTest, AnUnconfirmedUnknownWordIsRecordedButNeverSuggested) {
  TempFile userFile("");
  LatinLexicon lexicon;
  lexicon.setUserWordListPath(userFile.path());

  lexicon.rememberWord("thqrst");
  EXPECT_TRUE(lexicon.isUserWord("thqrst"));
  EXPECT_TRUE(lexicon.complete("thq", 10).empty())
      << "one sighting records the word, it does not recommend it";

  // ...and it really is on disk, so a relaunch starts from one sighting
  // rather than from zero.
  LatinLexicon reloaded;
  ASSERT_TRUE(reloaded.loadUserWordList(userFile.path()));
  EXPECT_TRUE(reloaded.isUserWord("thqrst"));
  EXPECT_TRUE(reloaded.complete("thq", 10).empty());

  // The second sighting confirms it, and now it is offered.
  reloaded.setUserWordListPath(userFile.path());
  EXPECT_TRUE(reloaded.rememberWord("THQRST")) << "case-insensitive";
  EXPECT_EQ(reloaded.complete("thq", 10),
            std::vector<std::string> { "thqrst" });
}

TEST(LatinLexiconTest, RememberWordAddsItsWeight) {
  TempFile userFile("");
  LatinLexicon lexicon;
  lexicon.setUserWordListPath(userFile.path());

  lexicon.rememberWord("ellipse", LatinLexicon::kExplicitAcceptWeight);
  EXPECT_EQ(lexicon.sourceTier("ellipse"), LatinLexicon::kConfirmedUserWordTier)
      << "one explicit accept confirms the word on its own";

  // The stored score really is the sum, and it survives a reload.
  lexicon.rememberWord("ellipse");
  LatinLexicon reloaded;
  ASSERT_TRUE(reloaded.loadUserWordList(userFile.path()));
  std::vector<std::string> completions = reloaded.complete("ellips", 10);
  ASSERT_EQ(completions.size(), 1u);
  EXPECT_EQ(completions[0], "ellipse");
  // score 3 == 2 (accept) + 1 (one typed sighting)
  TempFile expected("ellipse\t3\n");
  std::ifstream persisted(userFile.path());
  std::string line;
  ASSERT_TRUE(std::getline(persisted, line));
  EXPECT_EQ(line, "ellipse\t3");
}

TEST(LatinLexiconTest, CompleteTiesBreakAlphabetically) {
  // Same explicit rank for all three: an unranked line would instead get a
  // distinct file-order rank (see loadBuiltinWordList()), which is *not*
  // what this test is after -- it wants a genuine tie.
  TempFile file("zeta\t9\nzebra\t9\nzen\t9\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  std::vector<std::string> completions = lexicon.complete("ze", 10);
  ASSERT_EQ(completions.size(), 3u);
  EXPECT_EQ(completions[0], "zebra");
  EXPECT_EQ(completions[1], "zen");
  EXPECT_EQ(completions[2], "zeta");
}

TEST(LatinLexiconTest, CompleteLimitsToN) {
  TempFile file("aa\nab\nac\nad\nae\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  std::vector<std::string> completions = lexicon.complete("a", 2);
  EXPECT_EQ(completions.size(), 2u);
}

TEST(LatinLexiconTest, CompleteReturnsEmptyForNoMatchOrNoBudget) {
  TempFile file("acer\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(file.path()));

  EXPECT_TRUE(lexicon.complete("zzz", 10).empty());
  EXPECT_TRUE(lexicon.complete("a", 0).empty());
  EXPECT_TRUE(lexicon.complete("", 10).empty());
}

// Load order determines cross-file tiering (see loadBuiltinWordList()'s
// rank-offset doc): the file loaded first always outranks the file loaded
// second, regardless of the second file's own internal rank numbers. This
// is how Source/Data/latin-tech-seed.txt stays ahead of the dictionary.
TEST(LatinLexiconTest, EarlierLoadedFileOutranksLaterFileRegardlessOfItsOwnRanks) {
  TempFile techSeed("acer\t0\n");     // Loaded first, rank 0 within itself.
  TempFile dictionary("acerbic\t0\n");  // Loaded second, also rank 0 within itself.
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadBuiltinWordList(techSeed.path()));
  ASSERT_TRUE(lexicon.loadBuiltinWordList(dictionary.path()));

  EXPECT_LT(lexicon.rank("acer"), lexicon.rank("acerbic"));

  std::vector<std::string> completions = lexicon.complete("ace", 10);
  ASSERT_EQ(completions.size(), 2u);
  EXPECT_EQ(completions[0], "acer");
  EXPECT_EQ(completions[1], "acerbic");
}

// Performance floor for the P3 predictive-typing hot path: complete() has
// to run on (effectively) every keystroke of a Latin run, so it must stay
// well under a keystroke's budget even against a realistically large
// dictionary and random prefixes (not just the short, curated ones the
// other tests use, which could hide an accidentally-quadratic path).
TEST(LatinLexiconTest, CompletePerformanceOnRandomPrefixes) {
  LatinLexicon lexicon;
  {
    // A synthetic ~50k-word dictionary: every 3-letter combination of
    // a-z as a prefix, each with a handful of longer extensions, so
    // completion candidate sets are realistically sized.
    std::filesystem::path path = std::filesystem::temp_directory_path() /
        "bopomix_latin_lexicon_test_perf_dict.txt";
    {
      std::ofstream out(path);
      int rank = 0;
      for (char a = 'a'; a <= 'z'; ++a) {
        for (char b = 'a'; b <= 'z'; ++b) {
          std::string prefix { a, b };
          out << prefix << "xx\t" << rank++ << "\n";
          out << prefix << "yy\t" << rank++ << "\n";
          out << prefix << "zzlong\t" << rank++ << "\n";
        }
      }
    }
    ASSERT_TRUE(lexicon.loadBuiltinWordList(path.string()));
    std::filesystem::remove(path);
  }

  std::mt19937 rng(42);
  std::uniform_int_distribution<int> letter('a', 'z');
  std::uniform_int_distribution<int> lenDist(1, 3);
  std::vector<std::string> prefixes;
  prefixes.reserve(10000);
  for (int i = 0; i < 10000; ++i) {
    std::string prefix;
    int len = lenDist(rng);
    for (int j = 0; j < len; ++j) {
      prefix.push_back(static_cast<char>(letter(rng)));
    }
    prefixes.push_back(prefix);
  }

  auto start = std::chrono::steady_clock::now();
  for (const auto& prefix : prefixes) {
    lexicon.complete(prefix, 9);
  }
  auto elapsed = std::chrono::steady_clock::now() - start;
  double avgMicros =
      std::chrono::duration<double, std::micro>(elapsed).count() / prefixes.size();
  EXPECT_LT(avgMicros, 1000.0) << "average complete() call took " << avgMicros << "us";
}

}  // namespace McBopomofo::MixedScript
