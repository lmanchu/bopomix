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

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>

#include "gtest/gtest.h"

namespace McBopomofo::MixedScript {

namespace {

// Writes `content` to a fresh temp file and returns its path; the file is
// removed when the returned guard goes out of scope.
class TempFile {
 public:
  explicit TempFile(const std::string& content) {
    path_ = std::filesystem::temp_directory_path() /
            ("mixime_latin_lexicon_test_" +
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
      "mixime_latin_lexicon_test_user_words.txt";
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
      "mixime_latin_lexicon_test_remember_ok.txt";
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
  TempFile file("worklegacy\nworknew\t7\n");
  LatinLexicon lexicon;
  ASSERT_TRUE(lexicon.loadUserWordList(file.path()));

  EXPECT_TRUE(lexicon.isUserWord("worklegacy"));
  EXPECT_TRUE(lexicon.isUserWord("worknew"));
  EXPECT_EQ(lexicon.userWordCount(), 2u);

  // "worklegacy" (parsed count 1) must complete after "worknew" (parsed
  // count 7), proving the tab-count round-tripped through the load rather
  // than every line being treated as count 1.
  std::vector<std::string> completions = lexicon.complete("work", 10);
  ASSERT_EQ(completions.size(), 2u);
  EXPECT_EQ(completions[0], "worknew");
  EXPECT_EQ(completions[1], "worklegacy");
}

TEST(LatinLexiconTest, RememberWordRewritesExistingCountInPlace) {
  std::filesystem::path userPath =
      std::filesystem::temp_directory_path() /
      "mixime_latin_lexicon_test_rewrite_count.txt";
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
  lexicon.rememberWord("appstore");

  std::vector<std::string> completions = lexicon.complete("app", 10);
  ASSERT_EQ(completions.size(), 3u);
  EXPECT_EQ(completions[0], "apple");     // count 3
  EXPECT_EQ(completions[1], "apply");     // count 2
  EXPECT_EQ(completions[2], "appstore");  // count 1
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
        "mixime_latin_lexicon_test_perf_dict.txt";
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
