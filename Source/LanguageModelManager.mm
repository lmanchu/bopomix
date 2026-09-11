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

#import "LanguageModelManager.h"
#import "LanguageModelManager+Privates.h"
#import "McBopomofo-Swift.h"

#include "UTF8Helper.h"
#include "AssociatedPhrasesV2.h"

#include <atomic>

@import OpenCCBridge;

static const int kUserOverrideModelCapacity = 500;
static const double kObservedOverrideHalflife = 5400.0; // 1.5 hr.

static McBopomofo::McBopomofoLM gLanguageModelMcBopomofo;
static McBopomofo::McBopomofoLM gLanguageModelPlainBopomofo;
static McBopomofo::UserOverrideModel gUserOverrideModel(kUserOverrideModelCapacity, kObservedOverrideHalflife);
static McBopomofo::VariantAnnotator gVariantAnnotator;
static McBopomofo::MixedScript::LatinLexicon gLatinLexicon;
// Written only by the one-shot background load below, and only *before*
// gLatinLexiconReady is released; read only after acquiring that flag. See
// LTLoadMixedScriptLexicon().
static std::atomic<bool> gLatinLexiconReady { false };
static BOOL gLatinLexiconLoadStarted = NO;

static NSString *const kUserDataTemplateName = @"template-data";
static NSString *const kUserDataPlainBopomofoTemplateName = @"template-data-plain-bpmf";
static NSString *const kExcludedPhrasesMcBopomofoTemplateName = @"template-exclude-phrases";
static NSString *const kExcludedPhrasesPlainBopomofoTemplateName = @"template-exclude-phrases-plain-bpmf";
static NSString *const kPhraseReplacementTemplateName = @"template-phrases-replacement";
static NSString *const kTemplateExtension = @".txt";

@implementation LanguageModelManager

static void LTLoadLanguageModelFile(NSString *filenameWithoutExtension, McBopomofo::McBopomofoLM& lm)
{
    Class cls = NSClassFromString(@"McBopomofoInputMethodController");
    NSString *dataPath = [[NSBundle bundleForClass:cls] pathForResource:filenameWithoutExtension ofType:@"txt"];
    lm.loadLanguageModel(dataPath.UTF8String);
}

static void LTLoadAssociatedPhrases(McBopomofo::McBopomofoLM& lm)
{
    Class cls = NSClassFromString(@"McBopomofoInputMethodController");
    NSString *dataPath = [[NSBundle bundleForClass:cls] pathForResource:@"associated-phrases-v2" ofType:@"txt"];
    lm.loadAssociatedPhrasesV2(dataPath.UTF8String);
}

static void LTLoadVariantAnnotatorData()
{
    Class cls = NSClassFromString(@"McBopomofoInputMethodController");
    NSString *puaDataPath = [[NSBundle bundleForClass:cls] pathForResource:@"bpmfvs-pua" ofType:@"txt"];
    if (puaDataPath == nil) {
        NSLog(@"Error: No PUA data found in bundle");
        return;
    }

    NSString *variantsDataPath = [[NSBundle bundleForClass:cls] pathForResource:@"bpmfvs-variants" ofType:@"txt"];
    if (variantsDataPath == nil) {
        NSLog(@"Error: No variants data found in bundle");
        return;
    }

    BOOL puaLoaded = gVariantAnnotator.loadPUAFile(puaDataPath.UTF8String);
    BOOL variantsLoaded = gVariantAnnotator.loadVariantsFile(variantsDataPath.UTF8String);
    if (!gVariantAnnotator.loaded()) {
        NSLog(@"Error: VariantAnnotator not ready, puaLoaded: %d, variantsLoaded: %d", puaLoaded, variantsLoaded);
    }
}

// P1 zh/en mixed typing (see ~/.claude/plans/zhuyin-ime-personal.md).
// Loads the two bundled word lists plus the user's own learned-word file
// into gLatinLexicon. Safe to call more than once; only the first call
// does any work. This never touches gLanguageModelMcBopomofo's
// mixedScriptEnabled_ flag -- KeyHandler flips that per
// Preferences.mixedScriptEnabled, independent of whether the lexicon has
// been loaded.
//
// Loading is ~150 ms for 204k words, so it runs on a background queue
// rather than on the key thread inside +loadDataModels (which
// activateServer: calls, i.e. every time the user switches to this input
// method). The synchronization is the plain publish pattern and needs no
// lock: the background block is the only writer and it finishes every
// write before releasing gLatinLexiconReady; +latinLexicon is the only
// reader and hands out nothing until it has acquired that flag, so
// callers see either "not available yet" or a fully-built lexicon.
// MixedScriptTracker treats a null lexicon as "rules B/C do not apply",
// which for the fraction of a second before this lands is exactly right.
static void LTLoadMixedScriptLexicon()
{
    if (gLatinLexiconLoadStarted) {
        return;
    }
    gLatinLexiconLoadStarted = YES;

    Class cls = NSClassFromString(@"McBopomofoInputMethodController");
    NSString *wordsPath = [[NSBundle bundleForClass:cls] pathForResource:@"latin-words" ofType:@"txt"];
    NSString *techSeedPath = [[NSBundle bundleForClass:cls] pathForResource:@"latin-tech-seed" ofType:@"txt"];
    if (wordsPath == nil) {
        NSLog(@"Error: No latin-words.txt found in bundle");
    }
    if (techSeedPath == nil) {
        NSLog(@"Error: No latin-tech-seed.txt found in bundle");
    }
    // Resolved here rather than in the block: it reads Preferences, which
    // belongs on the main thread.
    NSString *userPath = [LanguageModelManager latinUserWordListPath];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // P3 predictive typing (see zhuyin-ime-personal.md's F3 scope):
        // tech-seed is loaded *before* the dictionary so its hand-ranked
        // terms always outrank every dictionary word regardless of the
        // dictionary's own SCOWL-tier rank -- see
        // LatinLexicon::loadBuiltinWordList()'s rank-offset comment for
        // why load order alone is enough to guarantee that.
        if (techSeedPath != nil) {
            gLatinLexicon.loadBuiltinWordList(techSeedPath.UTF8String);
        }
        if (wordsPath != nil) {
            gLatinLexicon.loadBuiltinWordList(wordsPath.UTF8String);
        }
        gLatinLexicon.setUserWordListPath(userPath.UTF8String);
        gLatinLexicon.loadUserWordList(userPath.UTF8String);
        gLatinLexiconReady.store(true, std::memory_order_release);
    });
}

+ (void)loadDataModels
{
    if (!gLanguageModelMcBopomofo.isDataModelLoaded()) {
        LTLoadLanguageModelFile(@"data", gLanguageModelMcBopomofo);
    }
    if (!gLanguageModelMcBopomofo.isAssociatedPhrasesV2Loaded()) {
        LTLoadAssociatedPhrases(gLanguageModelMcBopomofo);
    }

    if (!gLanguageModelPlainBopomofo.isDataModelLoaded()) {
        LTLoadLanguageModelFile(@"data-plain-bpmf", gLanguageModelPlainBopomofo);
    }
    if (!gLanguageModelPlainBopomofo.isAssociatedPhrasesV2Loaded()) {
        LTLoadAssociatedPhrases(gLanguageModelPlainBopomofo);
    }
    if (!gVariantAnnotator.loaded()) {
        LTLoadVariantAnnotatorData();
    }
    if (Preferences.mixedScriptEnabled) {
        // Only warm the Latin word lists for users who actually turned
        // mixed typing on; otherwise the first key handled with the
        // feature enabled starts the load (see KeyHandler's mixedScript
        // hook), and users who never enable it never pay for it.
        LTLoadMixedScriptLexicon();
    }
}

+ (void)loadDataModel:(InputMode)mode
{
    if ([mode isEqualToString:InputModeBopomofo]) {
        if (!gLanguageModelMcBopomofo.isDataModelLoaded()) {
            LTLoadLanguageModelFile(@"data", gLanguageModelMcBopomofo);
        }
        if (!gLanguageModelMcBopomofo.isAssociatedPhrasesV2Loaded()) {
            LTLoadAssociatedPhrases(gLanguageModelMcBopomofo);
        }
        if (!gVariantAnnotator.loaded()) {
            LTLoadVariantAnnotatorData();
        }
    }

    if ([mode isEqualToString:InputModePlainBopomofo]) {
        if (!gLanguageModelPlainBopomofo.isDataModelLoaded()) {
            LTLoadLanguageModelFile(@"data-plain-bpmf", gLanguageModelPlainBopomofo);
        }
        if (!gLanguageModelPlainBopomofo.isAssociatedPhrasesV2Loaded()) {
            LTLoadAssociatedPhrases(gLanguageModelPlainBopomofo);
        }
        if (!gVariantAnnotator.loaded()) {
            LTLoadVariantAnnotatorData();
        }
    }
    if (Preferences.mixedScriptEnabled) {
        // Only warm the Latin word lists for users who actually turned
        // mixed typing on; otherwise the first key handled with the
        // feature enabled starts the load (see KeyHandler's mixedScript
        // hook), and users who never enable it never pay for it.
        LTLoadMixedScriptLexicon();
    }
}

+ (void)loadUserPhrasesWithPlainBopomofoEnabled:(BOOL)userPhraseForPlainBopomofo
{
    gLanguageModelMcBopomofo.loadUserPhrases([self userPhrasesDataPathMcBopomofo].UTF8String, [self excludedPhrasesDataPathMcBopomofo].UTF8String);
    gLanguageModelPlainBopomofo.loadUserPhrases(userPhraseForPlainBopomofo ? [self userPhrasesDataPathPlainBopomofo].UTF8String : NULL,
        [self excludedPhrasesDataPathPlainBopomofo].UTF8String);
}

+ (void)loadUserPhraseReplacement
{
    gLanguageModelMcBopomofo.loadPhraseReplacementMap([self phraseReplacementDataPathMcBopomofo].UTF8String);
}

+ (void)setupDataModelValueConverter
{
    auto macroConverter = [](const std::string& input) {
        NSString *inputText = @(input.c_str());
        NSString *handled = [[InputMacroController shared] handle:inputText];
        return std::string(handled.UTF8String);
    };

    auto converter = [](const std::string& input) {
        if (!Preferences.chineseConversionEnabled) {
            return input;
        }

        if (Preferences.chineseConversionStyle == 0) {
            return input;
        }

        NSString *text = [[OpenCCBridge sharedInstance] convertToSimplified:@(input.c_str())];
        return std::string(text.UTF8String);
    };

    gLanguageModelMcBopomofo.setMacroConverter(macroConverter);
    gLanguageModelMcBopomofo.setExternalConverter(converter);
    gLanguageModelPlainBopomofo.setExternalConverter(converter);
}

+ (BOOL)checkIfUserDataFolderExists
{
    NSString *folderPath = [self dataFolderPath];
    BOOL isFolder = NO;
    BOOL folderExist = [[NSFileManager defaultManager] fileExistsAtPath:folderPath isDirectory:&isFolder];
    if (folderExist && !isFolder) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:folderPath error:&error];
        if (error) {
            NSLog(@"Failed to remove folder %@", error);
            return NO;
        }
        folderExist = NO;
    }
    if (!folderExist) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:folderPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Failed to create folder %@", error);
            return NO;
        }
    }
    return YES;
}

+ (BOOL)ensureFileExists:(NSString *)filePath populateWithTemplate:(NSString *)templateBasename extension:(NSString *)ext
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {

        NSURL *templateURL = [[NSBundle mainBundle] URLForResource:templateBasename withExtension:ext];
        NSData *templateData;
        if (templateURL) {
            templateData = [NSData dataWithContentsOfURL:templateURL];
        } else {
            templateData = [@"" dataUsingEncoding:NSUTF8StringEncoding];
        }

        BOOL result = [templateData writeToFile:filePath atomically:YES];
        if (!result) {
            NSLog(@"Failed to write file");
            return NO;
        }
    }
    return YES;
}

+ (BOOL)checkIfUserLanguageModelFilesExist
{
    if (![self checkIfUserDataFolderExists]) {
        return NO;
    }
    if (![self ensureFileExists:[self userPhrasesDataPathMcBopomofo] populateWithTemplate:kUserDataTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self userPhrasesDataPathPlainBopomofo] populateWithTemplate:kUserDataPlainBopomofoTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self excludedPhrasesDataPathMcBopomofo] populateWithTemplate:kExcludedPhrasesMcBopomofoTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self excludedPhrasesDataPathPlainBopomofo] populateWithTemplate:kExcludedPhrasesPlainBopomofoTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    if (![self ensureFileExists:[self phraseReplacementDataPathMcBopomofo] populateWithTemplate:kPhraseReplacementTemplateName extension:kTemplateExtension]) {
        return NO;
    }
    return YES;
}

+ (BOOL)checkIfUserPhraseExist:(NSString *)userPhrase key:(NSString *)key NS_SWIFT_NAME(checkIfExist(userPhrase:key:))
{
    std::string unigramKey(key.UTF8String);
    auto unigrams = gLanguageModelMcBopomofo.getUnigrams(unigramKey);
    std::string userPhraseString(userPhrase.UTF8String);
    for (const auto& unigram : unigrams) {
        if (unigram.value() == userPhraseString) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)_checkIfPhrase:(NSString *)phrase existAtPath:(NSString *)path
{
    NSString *exactPhrase = nil;
    NSString *key = nil;
    NSArray *components = [phrase componentsSeparatedByString:@" "];
    if (components.count != 2) {
        return NO;
    }
    exactPhrase = components[0];
    key = components[1];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    NSError *error = nil;
    NSString *content = [[NSString alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] encoding:NSUTF8StringEncoding error:&error];
    if (error != nil) {
        return NO;
    }
    NSArray *lines = [content componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *lineComponents = [trimmed componentsSeparatedByString:@" "];
        if (lineComponents.count != 2) {
            continue;
        }
        if ([lineComponents[0] isEqualToString:exactPhrase] &&
            [lineComponents[1] isEqualToString:key]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)_writePhrase:(NSString *)phrase atEndOfPath:(NSString *)path
{
    BOOL addLineBreakAtFront = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSError *error = nil;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&error];
        unsigned long long fileSize = [attr fileSize];
        if (!error && fileSize) {
            NSFileHandle *readFile = [NSFileHandle fileHandleForReadingAtPath:path];
            if (readFile) {
                [readFile seekToFileOffset:fileSize - 1];
                NSData *data = [readFile readDataToEndOfFile];
                const void *bytes = data.bytes;
                if (*(char *)bytes != '\n') {
                    addLineBreakAtFront = YES;
                }
                [readFile closeFile];
            }
        }
    }
    NSMutableString *currentMarkedPhrase = [NSMutableString string];
    if (addLineBreakAtFront) {
        [currentMarkedPhrase appendString:@"\n"];
    }
    [currentMarkedPhrase appendString:phrase];
    [currentMarkedPhrase appendString:@"\n"];

    NSFileHandle *writeFile = [NSFileHandle fileHandleForUpdatingAtPath:path];
    if (!writeFile) {
        return NO;
    }

    [writeFile seekToEndOfFile];
    NSData *data = [currentMarkedPhrase dataUsingEncoding:NSUTF8StringEncoding];
    [writeFile writeData:data];
    [writeFile closeFile];
    return YES;
}

+ (BOOL)_removePhrase:(NSString *)phrase atPath:(NSString *)path
{
    NSString *exactPhrase = nil;
    NSString *key = nil;
    NSArray *components = [phrase componentsSeparatedByString:@" "];
    if (components.count != 2) {
        return NO;
    }
    exactPhrase = components[0];
    key = components[1];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    NSError *error = nil;
    NSString *content = [[NSString alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] encoding:NSUTF8StringEncoding error:&error];
    if (error != nil) {
        return NO;
    }
    NSArray *lines = [content componentsSeparatedByString:@"\n"];

    BOOL result = NO;
    NSMutableString *mutableString = [NSMutableString string];
    for (NSString *line in lines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSArray *lineComponents = [trimmed componentsSeparatedByString:@" "];
        if (lineComponents.count != 2) {
            [mutableString appendString:line];
            [mutableString appendString:@"\n"];
            continue;
        }
        if ([lineComponents[0] isEqualToString:exactPhrase] &&
            [lineComponents[1] isEqualToString:key]) {
            result = YES;
            continue;
        }
        [mutableString appendString:line];
        [mutableString appendString:@"\n"];
    }
    if (result) {
        NSError *writeError;
        [mutableString writeToURL:[NSURL fileURLWithPath:path] atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (writeError != nil) {
            return NO;
        }
        return YES;
    }

    return NO;
}

+ (BOOL)writeUserPhrase:(NSString *)userPhrase
{
    if (![self checkIfUserLanguageModelFilesExist]) {
        return NO;
    }

    NSString *excludePath = [self excludedPhrasesDataPathMcBopomofo];
    [self _removePhrase:userPhrase atPath:excludePath];

    NSString *includePath = [self userPhrasesDataPathMcBopomofo];
    if ([self _checkIfPhrase:userPhrase existAtPath:includePath]) {
        return NO;
    }
    BOOL result = [self _writePhrase:userPhrase atEndOfPath:includePath];

    //  We use FSEventStream to monitor the change of the user phrase folder,
    //  so we don't have to load data here.
    //  [self loadUserPhrases];
    return result;
}

+ (BOOL)removeUserPhrase:(NSString *)userPhrase
{
    if (![self checkIfUserLanguageModelFilesExist]) {
        return NO;
    }

    NSString *includePath = [self userPhrasesDataPathMcBopomofo];
    [self _removePhrase:userPhrase atPath:includePath];

    NSString *excludePath = [self excludedPhrasesDataPathMcBopomofo];
    if ([self _checkIfPhrase:userPhrase existAtPath:excludePath]) {
        return NO;
    }
    BOOL result = [self _writePhrase:userPhrase atEndOfPath:excludePath];

    //  We use FSEventStream to monitor the change of the user phrase folder,
    //  so we don't have to load data here.
    //  [self loadUserPhrases];
    return result;
}

+ (NSString *)dataFolderPath
{
    BOOL useCustomLocation = Preferences.useCustomUserPhraseLocation;
    if (!useCustomLocation) {
        return [UserPhraseLocationHelper defaultUserPhraseLocation];
    }
    return Preferences.customUserPhraseLocation;
}

+ (NSString *)userPhrasesDataPathMcBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"data.txt"];
}

+ (NSString *)userPhrasesDataPathPlainBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"data-plain-bpmf.txt"];
}

+ (NSString *)excludedPhrasesDataPathMcBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"exclude-phrases.txt"];
}

+ (NSString *)excludedPhrasesDataPathPlainBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"exclude-phrases-plain-bpmf.txt"];
}

+ (NSString *)phraseReplacementDataPathMcBopomofo
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"phrases-replacement.txt"];
}

// P1 zh/en mixed typing: same folder as McBopomofo's own user phrases (see
// dataFolderPath above), so it moves with a custom user-phrase location
// and is included in the same backup/sync story users already have.
+ (NSString *)latinUserWordListPath
{
    return [[self dataFolderPath] stringByAppendingPathComponent:@"latin-user.txt"];
}

+ (McBopomofo::MixedScript::LatinLexicon *)latinLexicon
{
    LTLoadMixedScriptLexicon();
    if (!gLatinLexiconReady.load(std::memory_order_acquire)) {
        return nullptr;
    }
    return &gLatinLexicon;
}

+ (BOOL)latinLexiconReady
{
    LTLoadMixedScriptLexicon();
    return gLatinLexiconReady.load(std::memory_order_acquire) ? YES : NO;
}

+ (BOOL)ensureLatinUserWordListFolder
{
    return [self checkIfUserDataFolderExists];
}

+ (void)resetLatinLexiconForTesting
{
    // A load may already be in flight -- e.g. the test host app's own
    // +loadDataModels at launch, reading whatever Preferences.mixedScriptEnabled
    // is on disk at that moment, before any test's setUp has had a chance
    // to override it. LTLoadMixedScriptLexicon()'s background block is
    // documented to be gLatinLexicon's only writer between "load started"
    // and "load ready" (the plain-publish pattern its comment describes);
    // reset()ing concurrently with it would be a data race on the same
    // object from two threads. Wait for any such load to finish
    // publishing first -- bounded by the same ~150ms a load already
    // takes, never blocking forever since the background queue makes
    // progress independently of this (main-thread, testing-only) spin.
    // The deadline is belt and braces: an unbounded spin on the main
    // thread is a test-suite hang with no diagnosis attached, whereas
    // giving up loudly after an interval two orders of magnitude past the
    // real cost says what happened (docs/REVIEW-P3-2026-09-11.md's N14).
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
    while (gLatinLexiconLoadStarted && !gLatinLexiconReady.load(std::memory_order_acquire)) {
        if ([[NSDate date] compare:deadline] == NSOrderedDescending) {
            NSLog(@"warning: latin lexicon load did not publish within 30s; "
                  @"resetting anyway");
            break;
        }
        [NSThread sleepForTimeInterval:0.001];
    }
    gLatinLexicon.reset();
    gLatinLexiconLoadStarted = NO;
    gLatinLexiconReady.store(false, std::memory_order_release);
}

+ (BOOL)isLatinWordForTesting:(NSString *)word
{
    return gLatinLexiconReady.load(std::memory_order_acquire) && gLatinLexicon.isWord(word.UTF8String);
}

+ (McBopomofo::McBopomofoLM *)languageModelMcBopomofo
{
    return &gLanguageModelMcBopomofo;
}

+ (McBopomofo::McBopomofoLM *)languageModelPlainBopomofo
{
    return &gLanguageModelPlainBopomofo;
}

+ (McBopomofo::UserOverrideModel *)userOverrideModel
{
    return &gUserOverrideModel;
}

+ (McBopomofo::VariantAnnotator *)variantAnnotator
{
    return &gVariantAnnotator;
}

+ (BOOL)phraseReplacementEnabled
{
    return gLanguageModelMcBopomofo.phraseReplacementEnabled();
}

+ (void)setPhraseReplacementEnabled:(BOOL)phraseReplacementEnabled
{
    gLanguageModelMcBopomofo.setPhraseReplacementEnabled(phraseReplacementEnabled);
}

+ (nullable NSString *)readingFor:(NSString *)phrase
{
    if (!gLanguageModelMcBopomofo.isDataModelLoaded()) {
        [self loadDataModel:InputModeBopomofo];
    }

    std::string reading = gLanguageModelMcBopomofo.getReading(phrase.UTF8String);
    return !reading.empty() ? @(reading.c_str()) : nil;
}

+ (NSString *)annotateVariantForCharacters:(NSString *)inCharacters readings:(NSString *)inReadings
{
    McBopomofo::VariantAnnotator *annotator = LanguageModelManager.variantAnnotator;
    if (!annotator || !annotator->loaded()) {
        return inCharacters;
    }

    std::string value(inCharacters.UTF8String);
    std::string readingString(inReadings.UTF8String);
    std::vector<std::string> characters = McBopomofo::Split(value);
    std::vector<std::string> readings = McBopomofo::AssociatedPhrasesV2::SplitReadings(readingString);

    McBopomofo::VariantAnnotator::CombinedResult result = LanguageModelManager.variantAnnotator->annotate(characters,
                                                                                                          readings);
    return [[NSString alloc] initWithUTF8String:result.annotatedString.c_str()];
}


@end
