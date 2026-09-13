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

#include "bopomofo_shape_tracker.h"

#include "gtest/gtest.h"

namespace McBopomofo::MixedScript {

namespace {
const Formosa::Mandarin::BopomofoKeyboardLayout* Standard() {
  return Formosa::Mandarin::BopomofoKeyboardLayout::StandardLayout();
}

bool FeedAll(BopomofoShapeTracker* tracker, const std::string& keys) {
  bool result = true;
  for (char key : keys) {
    result = tracker->feed(Standard(), key);
  }
  return result;
}
}  // namespace

TEST(BopomofoShapeTrackerTest, StartsComposable) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.stillComposable());
}

// "su3" == the standard-layout keys for su3 (你 without the tone is
// actually "su", tone key '3' composes it) -- a completely normal
// consonant+medial single-syllable sequence should never be rejected.
TEST(BopomofoShapeTrackerTest, NormalSyllableStaysComposable) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 's'));  // consonant N
  EXPECT_TRUE(tracker.feed(Standard(), 'u'));  // medial I
  EXPECT_TRUE(tracker.stillComposable());
}

// A tone key never conflicts and carries no shape information.
TEST(BopomofoShapeTrackerTest, ToneKeyNeverConflicts) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 's'));
  EXPECT_TRUE(tracker.feed(Standard(), 'u'));
  EXPECT_TRUE(tracker.feed(Standard(), '3'));  // Tone3
  EXPECT_TRUE(tracker.stillComposable());
}

// "th": t -> CH (consonant), h -> C (consonant). Two different consonants
// in a row is the required early-reject example from
// zhuyin-ime-personal.md's P1 design section.
TEST(BopomofoShapeTrackerTest, ThRejectsAtSecondLetter) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 't'));
  EXPECT_FALSE(tracker.feed(Standard(), 'h'));
  EXPECT_FALSE(tracker.stillComposable());
}

TEST(BopomofoShapeTrackerTest, ThStaysRejectedForRestOfRun) {
  BopomofoShapeTracker tracker;
  FeedAll(&tracker, "th");
  ASSERT_FALSE(tracker.stillComposable());
  EXPECT_FALSE(tracker.feed(Standard(), 'e'));
  EXPECT_FALSE(tracker.stillComposable());
}

// "sl": s -> N (consonant), l -> AO (vowel) -- composable so far (a normal
// CV shape). A third letter that maps to a consonant (e.g. 'a' -> M) then
// regresses behind the vowel already set, per the other required
// early-reject example.
TEST(BopomofoShapeTrackerTest, SlThenConsonantRejectsAtThirdLetter) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 's'));
  EXPECT_TRUE(tracker.feed(Standard(), 'l'));
  EXPECT_TRUE(tracker.stillComposable());
  EXPECT_FALSE(tracker.feed(Standard(), 'a'));
  EXPECT_FALSE(tracker.stillComposable());
}

// The "regression" half of the consonant rule, on its own: a vowel is set
// first and *then* a consonant key arrives, with no second consonant to
// trip the "a different consonant was already set" branch instead. Without
// this, removing the hasMedial_/hasVowel_ check from feed()'s kConsonant
// case left the whole engine test suite green (mutation M2 in
// docs/REVIEW-P1-2026-09-10.md), because
// SlThenConsonantRejectsAtThirdLetter is caught by the other branch too.
TEST(BopomofoShapeTrackerTest, ConsonantAfterVowelRejects) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 'l'));  // vowel AO, no consonant yet
  EXPECT_TRUE(tracker.stillComposable());
  EXPECT_FALSE(tracker.feed(Standard(), 't'));  // consonant CH after a vowel
  EXPECT_FALSE(tracker.stillComposable());
}

// Same, for a medial rather than a vowel: 'j' -> U (medial), then a
// consonant.
TEST(BopomofoShapeTrackerTest, ConsonantAfterMedialRejects) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 'j'));  // medial U
  EXPECT_TRUE(tracker.stillComposable());
  EXPECT_FALSE(tracker.feed(Standard(), 's'));  // consonant N after a medial
  EXPECT_FALSE(tracker.stillComposable());
}

// And the medial-after-vowel regression, which had no test of its own
// either: 'i' -> O (vowel), then 'u' -> I (medial).
TEST(BopomofoShapeTrackerTest, MedialAfterVowelRejects) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 'i'));  // vowel O
  EXPECT_FALSE(tracker.feed(Standard(), 'u'));  // medial I after a vowel
  EXPECT_FALSE(tracker.stillComposable());
}

// A repeated identical key is not a conflict (harmless no-op overwrite).
TEST(BopomofoShapeTrackerTest, RepeatingSameKeyIsNotAConflict) {
  BopomofoShapeTracker tracker;
  EXPECT_TRUE(tracker.feed(Standard(), 's'));
  EXPECT_TRUE(tracker.feed(Standard(), 's'));
  EXPECT_TRUE(tracker.stillComposable());
}

TEST(BopomofoShapeTrackerTest, ResetClearsRejectedState) {
  BopomofoShapeTracker tracker;
  FeedAll(&tracker, "th");
  ASSERT_FALSE(tracker.stillComposable());
  tracker.reset();
  EXPECT_TRUE(tracker.stillComposable());
  EXPECT_TRUE(tracker.feed(Standard(), 's'));
}

}  // namespace McBopomofo::MixedScript
