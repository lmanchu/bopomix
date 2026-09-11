// Copyright (c) 2022 and onwards The McBopomofo Authors.
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

#import <Foundation/Foundation.h>
#import "KeyHandler.h"

NS_ASSUME_NONNULL_BEGIN

@interface LanguageModelManager : NSObject

+ (void)loadDataModel:(InputMode)mode;
+ (void)loadUserPhrasesWithPlainBopomofoEnabled:(BOOL)userPhraseForPlainBopomofo NS_SWIFT_NAME(loadUserPhrases(enableForPlainBopomofo:));
+ (void)loadUserPhraseReplacement;
+ (void)setupDataModelValueConverter;
+ (BOOL)checkIfUserLanguageModelFilesExist;

+ (BOOL)checkIfUserPhraseExist:(NSString *)userPhrase key:(NSString *)key NS_SWIFT_NAME(checkIfExist(userPhrase:key:));
+ (BOOL)writeUserPhrase:(NSString *)userPhrase;
+ (BOOL)removeUserPhrase:(NSString *)userPhrase;

+ (nullable NSString *)readingFor:(NSString *)phrase;

@property (class, readonly, nonatomic) NSString *dataFolderPath;
@property (class, readonly, nonatomic) NSString *userPhrasesDataPathMcBopomofo;
@property (class, readonly, nonatomic) NSString *userPhrasesDataPathPlainBopomofo;
@property (class, readonly, nonatomic) NSString *excludedPhrasesDataPathMcBopomofo;
@property (class, readonly, nonatomic) NSString *excludedPhrasesDataPathPlainBopomofo;
@property (class, readonly, nonatomic) NSString *phraseReplacementDataPathMcBopomofo;
@property (class, assign, nonatomic) BOOL phraseReplacementEnabled;

@end

/// The following methods are merely for testing.
@interface LanguageModelManager ()
+ (void)loadDataModels;
/// P1 zh/en mixed typing: whether the Latin word lists have finished
/// loading. They load on a background queue (they are ~200k words and used
/// to add ~150 ms to every activateServer:), so tests that exercise the
/// dictionary-backed rules have to wait for this rather than assume
/// +loadDataModels left everything ready.
@property (class, readonly, nonatomic) BOOL latinLexiconReady;
/// Undoes whatever loadBuiltinWordList()/loadUserWordList()/rememberWord()
/// have accumulated in the process-wide Latin lexicon and clears the
/// "already started" load gate, so the next access re-triggers a full
/// fresh load from disk. Fixes docs/REVERIFY-P1-2026-09-10.md's R12: every
/// XCTest KeyHandler-level test target shares this one process-wide
/// object, so an explicit Tab/candidate pick in one test silently changed
/// another test's "top completion" ranking whenever both ran in the same
/// process. Callers should set Preferences.useCustomUserPhraseLocation and
/// Preferences.customUserPhraseLocation to a throwaway folder *before*
/// calling this (matching the existing per-test temp-folder pattern),
/// since the reload that follows re-resolves +latinUserWordListPath from
/// whatever is current.
+ (void)resetLatinLexiconForTesting;
/// True if `word` is a known word in the process-wide Latin lexicon
/// (builtin or user store, matching LatinLexicon::isWord()). Exposes just
/// enough of the lexicon to Swift XCTest code for P3's eval categorization
/// (LatinCompletionKeyHandlerTests' testEval200LatinCompletion) without
/// needing full C++ interop from a .swift file.
+ (BOOL)isLatinWordForTesting:(NSString *)word;
@end

@interface LanguageModelManager ()
+ (NSString *)annotateVariantForCharacters:(NSString *)characters readings:(NSString *)readings NS_SWIFT_NAME(annotateVariant(characters:readings:));
@end

NS_ASSUME_NONNULL_END
