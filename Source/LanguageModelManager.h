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
/// P1 zh/en mixed typing: re-reads `latin-user.txt` from wherever
/// +dataFolderPath resolves to *now*, replacing the Latin lexicon's user
/// store (the built-in word lists are left alone). No-op while the lexicon
/// is still loading -- the load reads the same preference itself, so it
/// already lands on the current folder.
///
/// Called from the same place the Chinese user phrases are reloaded
/// (AppDelegate's updateUserPhrases(), i.e. on launch, on a
/// userPhraseLocationDidChange notification, and on an FSEvent in the
/// folder). Without it, moving the user-phrase folder left the old
/// folder's Latin words in memory while writes went to the new folder's
/// file -- docs/REVERIFY-P3-2026-09-12.md's P-1.
+ (void)reloadLatinUserWordList;
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
/// process. Callers should set +dataFolderOverrideForTesting to a
/// throwaway folder *before* calling this (matching the existing per-test
/// temp-folder pattern), since the reload that follows re-resolves
/// +latinUserWordListPath from whatever is current.
+ (void)resetLatinLexiconForTesting;
/// When non-nil, +dataFolderPath returns this instead of consulting
/// Preferences at all -- which is the point: `UseCustomUserPhraseLocation`
/// / `CustomUserPhraseLocation` are keys in the real
/// `io.github.lmanchu.bopomix` domain, shared by every
/// process on the machine, so a test that redirected its user-data folder
/// by writing them was redirecting the *installed* input method too, and
/// was one lost race away from having its own writes land in the real
/// folder. That is exactly what `-parallel-testing-enabled YES` did:
/// 130 corpus words in the developer's own `latin-user.txt`
/// (docs/REVERIFY-P3-2026-09-12.md's P-2). A process-local override cannot
/// do that no matter how the suite is scheduled.
///
/// Set it in `setUpWithError()` and clear it in a teardown block. Nothing
/// in production ever sets it.
@property (class, nullable, copy, nonatomic) NSString *dataFolderOverrideForTesting;
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
