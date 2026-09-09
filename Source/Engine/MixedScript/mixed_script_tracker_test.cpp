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

#include "mixed_script_tracker.h"

#include "gtest/gtest.h"

namespace McBopomofo::MixedScript {

namespace {
const Formosa::Mandarin::BopomofoKeyboardLayout* Standard() {
  return Formosa::Mandarin::BopomofoKeyboardLayout::StandardLayout();
}
}  // namespace

// Rule A: "th" is structurally dead by the 2nd letter (see
// BopomofoShapeTrackerTest.ThRejectsAtSecondLetter) regardless of the
// dictionary, and the tracker should surface that immediately.
TEST(MixedScriptTrackerTest, RuleA_ThIsLatinByThirdLetter) {
  LatinLexicon lexicon;  // Empty: rule A must not depend on the dictionary.
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 't'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'h'), Verdict::kLatin);
  EXPECT_EQ(tracker.feedKey(Standard(), 'e'), Verdict::kLatin);
  EXPECT_TRUE(tracker.isLatinLocked());
  EXPECT_EQ(tracker.latinRun(), "the");
}

TEST(MixedScriptTrackerTest, RuleA_SlThenConsonantIsLatin) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 's'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'l'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kLatin);
  EXPECT_EQ(tracker.latinRun(), "sla");
}

// Rule B: "ai" (a -> M consonant, i -> O vowel) keeps a live Bopomofo
// shape the whole time, so once it matches a dictionary entry it is
// genuinely ambiguous, not an immediate Latin verdict.
TEST(MixedScriptTrackerTest, RuleB_DictionaryWordWithLiveShapeIsAmbiguous) {
  LatinLexicon lexicon;
  lexicon.rememberWord("ai");
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'i'), Verdict::kAmbiguous);
  EXPECT_FALSE(tracker.isLatinLocked());
}

TEST(MixedScriptTrackerTest, RuleB_ThreeLetterDictionaryWordIsAmbiguous) {
  LatinLexicon lexicon;
  lexicon.rememberWord("app");
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kAmbiguous);
}

// Rule C: a trailing space after a dictionary-word run (rule B) promotes
// the verdict to kLatin ("詞典＋空白→英文", 2026-09-09 decision); without
// the trailing space it stays an ambiguous Chinese default.
TEST(MixedScriptTrackerTest, RuleC_TrailingSpacePromotesAmbiguousToLatin) {
  LatinLexicon lexicon;
  lexicon.rememberWord("ai");
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'a');
  tracker.feedKey(Standard(), 'i');

  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kLatin);
}

TEST(MixedScriptTrackerTest, RuleC_NoTrailingSpaceStaysAmbiguous) {
  LatinLexicon lexicon;
  lexicon.rememberWord("ai");
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'a');
  tracker.feedKey(Standard(), 'i');

  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/false), Verdict::kAmbiguous);
}

TEST(MixedScriptTrackerTest, RuleA_BoundaryAlwaysReportsLatinOnceLocked) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  ASSERT_TRUE(tracker.isLatinLocked());

  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/false), Verdict::kLatin);
  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kLatin);
}

// A single letter must never count as an ambiguous dictionary word, even
// if (hypothetically) it were in the lexicon -- see
// MixedScriptTracker::kMinAmbiguousWordLength.
TEST(MixedScriptTrackerTest, SingleLetterNeverAmbiguous) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kChinese);
  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kChinese);
}

TEST(MixedScriptTrackerTest, ResetClearsRunAndLock) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  ASSERT_TRUE(tracker.hasPendingRun());

  tracker.reset();
  EXPECT_FALSE(tracker.hasPendingRun());
  EXPECT_FALSE(tracker.isLatinLocked());
  EXPECT_EQ(tracker.latinRun(), "");
}

TEST(MixedScriptTrackerTest, LatinRunPreservesOriginalCase) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'T');
  tracker.feedKey(Standard(), 'h');
  EXPECT_EQ(tracker.latinRun(), "Th");
}

// A plain Chinese run (no dictionary hit, shape alive) reports kChinese and
// leaves nothing "pending" from the caller's point of view beyond the
// normal reading buffer -- MixedScriptTracker does not itself decide to
// abandon the real Bopomofo path here.
TEST(MixedScriptTrackerTest, PlainChineseRunStaysChinese) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 's'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'u'), Verdict::kChinese);
  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kChinese);
}

TEST(MixedScriptTrackerTest, PopLastLatinCharShortensALockedRun) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  tracker.feedKey(Standard(), 'e');
  ASSERT_EQ(tracker.latinRun(), "the");
  ASSERT_TRUE(tracker.isLatinLocked());

  tracker.popLastLatinChar();
  EXPECT_EQ(tracker.latinRun(), "th");
  EXPECT_TRUE(tracker.isLatinLocked());
}

TEST(MixedScriptTrackerTest, PopLastLatinCharResetsAnUnlockedRun) {
  LatinLexicon lexicon;
  lexicon.rememberWord("ai");
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'a');
  tracker.feedKey(Standard(), 'i');
  ASSERT_FALSE(tracker.isLatinLocked());

  tracker.popLastLatinChar();
  EXPECT_FALSE(tracker.hasPendingRun());
  EXPECT_FALSE(tracker.isLatinLocked());
}

TEST(IsAllAsciiLettersTest, AcceptsLettersOnly) {
  EXPECT_TRUE(IsAllAsciiLetters("acer"));
  EXPECT_TRUE(IsAllAsciiLetters("Acer"));
  EXPECT_TRUE(IsAllAsciiLetters("THE"));
}

TEST(IsAllAsciiLettersTest, RejectsEmptyOrNonLetters) {
  EXPECT_FALSE(IsAllAsciiLetters(""));
  EXPECT_FALSE(IsAllAsciiLetters("ace1"));
  EXPECT_FALSE(IsAllAsciiLetters("你好"));
  EXPECT_FALSE(IsAllAsciiLetters("a b"));
}

}  // namespace McBopomofo::MixedScript
