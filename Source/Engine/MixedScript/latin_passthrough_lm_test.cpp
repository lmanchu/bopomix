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

#include "latin_passthrough_lm.h"

#include <algorithm>

#include "gtest/gtest.h"

namespace McBopomofo::MixedScript {

TEST(LatinPassthroughLMTest, RegisterSoleEntryIsTheOnlyUnigram) {
  LatinPassthroughLM lm;
  lm.registerSoleEntry("_latin_", "acer");

  ASSERT_TRUE(lm.hasUnigrams("_latin_"));
  auto unigrams = lm.getUnigrams("_latin_");
  ASSERT_EQ(unigrams.size(), 1u);
  EXPECT_EQ(unigrams[0].value(), "acer");
  EXPECT_TRUE(lm.hasValue("_latin_", "acer"));
}

TEST(LatinPassthroughLMTest, RegisterSoleEntryReplacesAPreviousRun) {
  LatinPassthroughLM lm;
  lm.registerSoleEntry("_latin_", "acer");
  lm.registerSoleEntry("_latin_", "gmail");

  auto unigrams = lm.getUnigrams("_latin_");
  ASSERT_EQ(unigrams.size(), 1u);
  EXPECT_EQ(unigrams[0].value(), "gmail");
}

// The whole reason clearKey() exists: the McBopomofoLM that owns this LM is
// process-wide, shared by every KeyHandler/text field, so a synthetic entry
// has to stop existing the moment ReadingGrid has snapshotted it. Nothing
// tested this before -- turning clearKey() into a no-op left all 156 engine
// tests green (mutation M4 in docs/REVIEW-P1-2026-09-10.md).
TEST(LatinPassthroughLMTest, ClearKeyRemovesOnlyThatKey) {
  LatinPassthroughLM lm;
  lm.registerSoleEntry("_latin_", "acer");
  lm.registerAlternate("ㄇㄣ", "app", -3.5);

  lm.clearKey("_latin_");
  EXPECT_FALSE(lm.hasUnigrams("_latin_"));
  EXPECT_TRUE(lm.getUnigrams("_latin_").empty());
  EXPECT_FALSE(lm.hasValue("_latin_", "acer"));
  EXPECT_TRUE(lm.hasUnigrams("ㄇㄣ"));
}

TEST(LatinPassthroughLMTest, ClearRemovesEverything) {
  LatinPassthroughLM lm;
  lm.registerSoleEntry("_latin_", "acer");
  lm.registerAlternate("ㄇㄣ", "app", -3.5);

  lm.clear();
  EXPECT_FALSE(lm.hasUnigrams("_latin_"));
  EXPECT_FALSE(lm.hasUnigrams("ㄇㄣ"));
}

TEST(LatinPassthroughLMTest, UnknownKeyHasNothing) {
  LatinPassthroughLM lm;
  EXPECT_FALSE(lm.hasUnigrams("ㄇㄣ"));
  EXPECT_TRUE(lm.getUnigrams("ㄇㄣ").empty());
  EXPECT_FALSE(lm.hasValue("ㄇㄣ", "app"));
}

// A rule-B alternate has to sit just *below* the reading's best Chinese
// unigram, not at the bottom of the list: ReadingGrid orders a node's
// candidates strictly by score, so the old fixed -99 put the English form
// 50-70 Tab presses away (see the class doc and the review's N2).
TEST(LatinPassthroughLMTest, ScoreJustBelowSitsUnderTheTopUnigramOnly) {
  const double kTop = -3.5;
  const double kSecond = -4.2;
  double alternate = LatinPassthroughLM::ScoreJustBelow(kTop);

  EXPECT_LT(alternate, kTop);
  EXPECT_GT(alternate, kSecond);
}

TEST(LatinPassthroughLMTest, RegisterAlternateKeepsTheRegisteredScore) {
  LatinPassthroughLM lm;
  lm.registerAlternate("ㄇㄣ", "app",
                       LatinPassthroughLM::ScoreJustBelow(-3.5));

  auto unigrams = lm.getUnigrams("ㄇㄣ");
  ASSERT_EQ(unigrams.size(), 1u);
  EXPECT_EQ(unigrams[0].value(), "app");
  EXPECT_LT(unigrams[0].score(), -3.5);
  EXPECT_GT(unigrams[0].score(), -3.6);
}

}  // namespace McBopomofo::MixedScript
