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

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>

#include "gtest/gtest.h"

namespace McBopomofo::MixedScript {

namespace {
const Formosa::Mandarin::BopomofoKeyboardLayout* Standard() {
  return Formosa::Mandarin::BopomofoKeyboardLayout::StandardLayout();
}

// A throwaway built-in word list on disk. Needed because "built-in word"
// and "user word" are now different things to onBoundary(), and
// rememberWord() can only produce the latter.
class TempWordList {
 public:
  explicit TempWordList(const std::string& content) {
    path_ = std::filesystem::temp_directory_path() /
            ("mixime_tracker_test_" +
             std::to_string(reinterpret_cast<uintptr_t>(this)) + ".txt");
    std::ofstream file(path_);
    file << content;
  }
  ~TempWordList() { std::filesystem::remove(path_); }
  std::string path() const { return path_.string(); }

 private:
  std::filesystem::path path_;
};
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

// Rule B: "app" (a -> M consonant, p -> EN vowel twice) keeps a live
// Bopomofo shape the whole time, so once it matches a dictionary entry it
// is genuinely ambiguous, not an immediate Latin verdict.
TEST(MixedScriptTrackerTest, RuleB_ThreeLetterDictionaryWordIsAmbiguous) {
  LatinLexicon lexicon;
  lexicon.rememberWord("app");
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kAmbiguous);
}

// Two-letter runs never reach rule B, however good a dictionary word they
// are: on the standard layout they are also complete tone-1 syllables
// ("ai" = ㄇㄛ, "up" = ㄧㄣ, "el" = ㄍㄠ), and treating them as English
// rewrote ordinary Chinese input. See kMinAmbiguousWordLength and
// docs/REVIEW-P1-2026-09-10.md's B1.
TEST(MixedScriptTrackerTest, TwoLetterDictionaryWordIsNeverAmbiguous) {
  LatinLexicon lexicon;
  lexicon.rememberWord("ai");
  MixedScriptTracker tracker(&lexicon);

  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'i'), Verdict::kChinese);
  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kChinese);
  EXPECT_FALSE(tracker.isLatinLocked());
}

// A trailing space commits a still-composable run as English only when the
// word is in the *user's own* store (a word they previously picked by
// hand). This is the 2026-09-10 replacement for the automatic
// "詞典＋空白→英文" rule.
TEST(MixedScriptTrackerTest, TrailingSpacePromotesAUserWordToLatin) {
  LatinLexicon lexicon;
  lexicon.rememberWord("app");  // rememberWord() == the user's own store.
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'a');
  tracker.feedKey(Standard(), 'p');
  tracker.feedKey(Standard(), 'p');

  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kLatin);
}

TEST(MixedScriptTrackerTest, TrailingSpaceLeavesABuiltinWordAmbiguous) {
  LatinLexicon lexicon;
  TempWordList builtin("app\n");
  ASSERT_TRUE(lexicon.loadBuiltinWordList(builtin.path()));
  ASSERT_TRUE(lexicon.isWord("app"));
  ASSERT_FALSE(lexicon.isUserWord("app"));
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'a');
  tracker.feedKey(Standard(), 'p');
  tracker.feedKey(Standard(), 'p');

  // Chinese by default, with the English form offered as a candidate --
  // the space is how tone 1 is typed, so it cannot also mean "this was
  // English" for every word in a 200k-entry list.
  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kAmbiguous);
}

TEST(MixedScriptTrackerTest, NoTrailingSpaceStaysAmbiguous) {
  LatinLexicon lexicon;
  lexicon.rememberWord("app");
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'a');
  tracker.feedKey(Standard(), 'p');
  tracker.feedKey(Standard(), 'p');

  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/false), Verdict::kAmbiguous);
}

// A null lexicon (the app's state while the word lists are still loading
// off the key thread) must leave rule A working and simply skip rules B/C.
TEST(MixedScriptTrackerTest, NullLexiconStillRunsRuleA) {
  MixedScriptTracker tracker(nullptr);

  EXPECT_EQ(tracker.feedKey(Standard(), 't'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'h'), Verdict::kLatin);
  EXPECT_EQ(tracker.onBoundary(/*isSpaceOrEnd=*/true), Verdict::kLatin);
}

TEST(MixedScriptTrackerTest, SetLexiconTakesEffectForLaterRuns) {
  LatinLexicon lexicon;
  lexicon.rememberWord("app");
  MixedScriptTracker tracker(nullptr);

  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kChinese);
  tracker.reset();

  tracker.setLexicon(&lexicon);
  EXPECT_EQ(tracker.feedKey(Standard(), 'a'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'p'), Verdict::kAmbiguous);
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
  lexicon.rememberWord("app");
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 'a');
  tracker.feedKey(Standard(), 'p');
  tracker.feedKey(Standard(), 'p');
  ASSERT_FALSE(tracker.isLatinLocked());

  tracker.popLastLatinChar();
  EXPECT_FALSE(tracker.hasPendingRun());
  EXPECT_FALSE(tracker.isLatinLocked());
}

// Backspacing a locked run all the way to empty has to drop the lock too,
// or every following key stays English with no way out except Esc or a
// non-letter key. See docs/REVIEW-P1-2026-09-10.md's B5.
TEST(MixedScriptTrackerTest, PopLastLatinCharToEmptyClearsTheLock) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  ASSERT_TRUE(tracker.isLatinLocked());

  tracker.popLastLatinChar();
  EXPECT_TRUE(tracker.isLatinLocked());
  tracker.popLastLatinChar();
  EXPECT_FALSE(tracker.hasPendingRun());
  EXPECT_FALSE(tracker.isLatinLocked());

  // ...and the shape tracker is usable again for a fresh Chinese syllable.
  EXPECT_EQ(tracker.feedKey(Standard(), 'g'), Verdict::kChinese);
  EXPECT_EQ(tracker.feedKey(Standard(), 'l'), Verdict::kChinese);
}

// P3: accepting a completion (Tab or the completion candidate window)
// replaces the run's text and keeps the lock, so more typing keeps
// extending the completed word rather than reopening rule A/B analysis.
TEST(MixedScriptTrackerTest, AcceptCompletionReplacesRunAndStaysLocked) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  ASSERT_TRUE(tracker.isLatinLocked());
  ASSERT_EQ(tracker.latinRun(), "th");

  tracker.acceptCompletion("they");
  EXPECT_TRUE(tracker.isLatinLocked());
  EXPECT_EQ(tracker.latinRun(), "they");

  // Typing on keeps extending the completed word, not "th".
  EXPECT_EQ(tracker.feedKey(Standard(), 'r'), Verdict::kLatin);
  EXPECT_EQ(tracker.latinRun(), "theyr");
}

// Backspacing after accepting a completion shortens the *completed* word,
// exactly like backspacing any other locked run (see
// PopLastLatinCharShortensALockedRun) -- accepting one must not leave any
// different bookkeeping behind.
TEST(MixedScriptTrackerTest, PopLastLatinCharAfterAcceptingCompletion) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  tracker.acceptCompletion("they");

  tracker.popLastLatinChar();
  EXPECT_TRUE(tracker.isLatinLocked());
  EXPECT_EQ(tracker.latinRun(), "the");
}

// P3 fix #2 (see zhuyin-ime-personal.md's P3 fix #2 and
// LatinLexicon::rememberWord()'s use-count doc): acceptCompletion() marks
// the run as already remembered so KeyHandler's natural-typing learn hook
// does not double-count it when the same run later reaches an ordinary
// boundary commit.
TEST(MixedScriptTrackerTest, AcceptCompletionMarksTheRunAlreadyRemembered) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  EXPECT_FALSE(tracker.latinRunAlreadyRemembered());

  tracker.acceptCompletion("they");
  EXPECT_TRUE(tracker.latinRunAlreadyRemembered());
}

// Typing more letters after accepting a completion changes the run's text,
// so the "already remembered" flag must not still describe it -- the
// longer/different word the user ends up committing should be eligible for
// natural-typing learning again.
TEST(MixedScriptTrackerTest, TypingMoreAfterAcceptingCompletionClearsAlreadyRemembered) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  tracker.acceptCompletion("they");
  ASSERT_TRUE(tracker.latinRunAlreadyRemembered());

  tracker.feedKey(Standard(), 'r');
  EXPECT_FALSE(tracker.latinRunAlreadyRemembered());
}

// Backspacing after accepting a completion also changes the run's text.
TEST(MixedScriptTrackerTest, PopLastLatinCharAfterAcceptingCompletionClearsAlreadyRemembered) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  tracker.acceptCompletion("they");
  ASSERT_TRUE(tracker.latinRunAlreadyRemembered());

  tracker.popLastLatinChar();
  EXPECT_FALSE(tracker.latinRunAlreadyRemembered());
}

// reset() (a fresh run, or the run being fully committed/discarded) must
// not leave a stale "already remembered" flag behind for the next run.
TEST(MixedScriptTrackerTest, ResetClearsAlreadyRemembered) {
  LatinLexicon lexicon;
  MixedScriptTracker tracker(&lexicon);
  tracker.feedKey(Standard(), 't');
  tracker.feedKey(Standard(), 'h');
  tracker.acceptCompletion("they");
  ASSERT_TRUE(tracker.latinRunAlreadyRemembered());

  tracker.reset();
  EXPECT_FALSE(tracker.latinRunAlreadyRemembered());
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
