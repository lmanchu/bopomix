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

#include <cstdio>
#include <filesystem>
#include <fstream>

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

}  // namespace McBopomofo::MixedScript
