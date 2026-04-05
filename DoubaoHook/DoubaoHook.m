#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// ═══════════════════════════════════════════════════
// DoubaoHook v6: progressive diagnostic tests
// ═══════════════════════════════════════════════════
// TEST_LEVEL controls what the hook does:
//   0 = pure passthrough (known stable)
//   1 = increment counter only
//   2 = read [text isKindOfClass:] before original
//   3 = copy text before original
//   4 = copy text + dispatch_async empty block
//   5 = copy text + dispatch_async with file write
//   6 = full snippet processing

#define TEST_LEVEL 6

static NSString *g_logPath = nil;
static void hookLog(NSString *msg) {
    if (!g_logPath) {
        g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:
                     @"Library/Application Support/Type4Me/doubao-hook.log"];
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                    dateStyle:NSDateFormatterNoStyle
                                                    timeStyle:NSDateFormatterMediumStyle], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:g_logPath contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ── Snippet engine ──

static NSArray *loadSnippetRules(void) {
    NSString *home = NSHomeDirectory();
    NSMutableArray *all = [NSMutableArray array];
    for (NSString *file in @[@"builtin-snippets.json", @"snippets.json"]) {
        NSString *path = [home stringByAppendingPathComponent:
                          [@"Library/Application Support/Type4Me/" stringByAppendingString:file]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        NSArray *entries = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![entries isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *e in entries) {
            if ([e[@"trigger"] length] > 0 && e[@"replacement"])
                [all addObject:e];
        }
    }
    return all;
}

static NSRegularExpression *buildFlexRegex(NSString *trigger) {
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < trigger.length; i++) {
        unichar c = [trigger characterAtIndex:i];
        if (![[NSCharacterSet whitespaceCharacterSet] characterIsMember:c])
            [s appendFormat:@"%C", c];
    }
    if (s.length == 0) return nil;
    NSMutableString *p = [NSMutableString stringWithString:@"(?<![a-zA-Z0-9])"];
    for (NSUInteger i = 0; i < s.length; i++) {
        if (i > 0) [p appendString:@"\\s*"];
        unichar c = [s characterAtIndex:i];
        [p appendString:[NSRegularExpression escapedPatternForString:
                         [NSString stringWithCharacters:&c length:1]]];
    }
    [p appendString:@"(?![a-zA-Z0-9])"];
    return [NSRegularExpression regularExpressionWithPattern:p
                                                    options:NSRegularExpressionCaseInsensitive
                                                      error:nil];
}

// Pre-compiled snippet rules (loaded once at init, no runtime file I/O)
static NSArray *g_snippetRegexes = nil;

static void preloadSnippets(void) {
    NSArray *rules = loadSnippetRules();
    NSMutableArray *compiled = [NSMutableArray array];
    for (NSDictionary *rule in rules) {
        NSRegularExpression *regex = buildFlexRegex(rule[@"trigger"]);
        if (regex)
            [compiled addObject:@{@"regex": regex, @"replacement": rule[@"replacement"]}];
    }
    g_snippetRegexes = [compiled copy];
}

static NSString *applySnippets(NSString *text) {
    if (!g_snippetRegexes) return text;
    NSMutableString *result = [text mutableCopy];
    for (NSDictionary *rule in g_snippetRegexes) {
        [rule[@"regex"] replaceMatchesInString:result options:0
                                        range:NSMakeRange(0, result.length)
                                 withTemplate:[NSRegularExpression escapedTemplateForString:rule[@"replacement"]]];
    }
    return result;
}

static IMP g_originalInsertTextWithFlags = NULL;
static IMP g_originalInsertText2 = NULL;
static volatile int64_t g_callCount = 0;

// Deduplication: skip duplicate notifications for the same text within 2 seconds
static NSString *g_lastNotifiedText = nil;
static CFAbsoluteTime g_lastNotifiedTime = 0;

// Block duplicate insertText calls after a snippet match (three-pass sends text twice)
static CFAbsoluteTime g_lastSnippetMatchTime = 0;
static const CFTimeInterval kBlockInsertAfterSnippetSeconds = 2.0;

// 2-param hook: only blocks duplicate calls after snippet match, otherwise pure passthrough
static void hooked_insertText_replacementRange_2param(
    id self, SEL _cmd, id text, NSRange range
) {
    CFAbsoluteTime now2 = CFAbsoluteTimeGetCurrent();
    if (g_lastSnippetMatchTime > 0 && (now2 - g_lastSnippetMatchTime) < kBlockInsertAfterSnippetSeconds) {
        NSString *str = nil;
        if ([text isKindOfClass:[NSString class]]) str = text;
        else if ([text isKindOfClass:[NSAttributedString class]]) str = [(NSAttributedString *)text string];
        BOOL isASRLike = str && (str.length >= range.length) && (str.length >= 2);
        if (isASRLike) {
            NSString *copy = [str copy];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                hookLog([NSString stringWithFormat:@"BLOCKED 2-param dup: len=%lu", (unsigned long)copy.length]);
            });
            return;
        }
    }
    ((void (*)(id, SEL, id, NSRange))g_originalInsertText2)(self, _cmd, text, range);
}

// 3-param hook: main ASR processing
static void hooked_insertText_replacementRange_validFlags(
    id self, SEL _cmd, id text, NSRange range, uint64_t validFlags
) {
#if TEST_LEVEL >= 1
    // Level 1: just increment a counter (minimal side effect)
    __sync_fetch_and_add(&g_callCount, 1);
#endif

#if TEST_LEVEL >= 2
    // Level 2: read text type (ObjC message send on text parameter)
    BOOL isString = [text isKindOfClass:[NSString class]];
    BOOL isAttrString = !isString && [text isKindOfClass:[NSAttributedString class]];
    (void)isString; (void)isAttrString;
#endif

#if TEST_LEVEL >= 3
    // Level 3: copy text to a local variable (retains the object)
    NSString *textCopy = nil;
    if ([text isKindOfClass:[NSString class]]) {
        textCopy = [(NSString *)text copy];
    } else if ([text isKindOfClass:[NSAttributedString class]]) {
        textCopy = [[(NSAttributedString *)text string] copy];
    }
    (void)textCopy; // suppress unused warning
#endif

    // Block duplicate insertText after snippet match (three-pass sends text twice)
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_lastSnippetMatchTime > 0 && (now - g_lastSnippetMatchTime) < kBlockInsertAfterSnippetSeconds) {
        BOOL isASRLike = textCopy && (textCopy.length >= range.length) && (textCopy.length >= 2);
        if (isASRLike) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                hookLog([NSString stringWithFormat:@"BLOCKED dup insertText: '%@'",
                         [textCopy substringToIndex:MIN(textCopy.length, 30)]]);
            });
            g_lastSnippetMatchTime = 0;
            return;  // skip original call entirely
        }
    }

    // Call original
    ((void (*)(id, SEL, id, NSRange, uint64_t))g_originalInsertTextWithFlags)(
        self, _cmd, text, range, validFlags
    );

    // ASR detection: for typing, range.length > text.length (pinyin is longer than Chinese chars)
    // For ASR, range.length <= text.length (replacing marked text of similar length)
    BOOL isASR = textCopy && (textCopy.length >= range.length) && (textCopy.length >= 2);

    // Log all ASR insertText calls for diagnostics
    if (isASR) {
        NSString *logText = textCopy;
        NSRange logRange = range;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            hookLog([NSString stringWithFormat:@"ASR insertText: len=%lu range=%lu+%lu text='%@'",
                     (unsigned long)logText.length,
                     (unsigned long)logRange.location, (unsigned long)logRange.length,
                     logText.length > 40 ? [NSString stringWithFormat:@"%@...%@",
                         [logText substringToIndex:20],
                         [logText substringFromIndex:logText.length - 20]] : logText]);
        });
    }

    if (isASR) {
        NSString *captured = [textCopy copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString *processed = applySnippets(captured);
            if (![processed isEqualToString:captured]) {
                // Deduplicate: skip if same text was just notified
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                BOOL isDuplicate = NO;
                @synchronized ([NSNull null]) {
                    if (g_lastNotifiedText && [g_lastNotifiedText isEqualToString:captured]
                        && (now - g_lastNotifiedTime) < 2.0) {
                        isDuplicate = YES;
                    } else {
                        g_lastNotifiedText = [captured copy];
                        g_lastNotifiedTime = now;
                    }
                }

                if (!isDuplicate) {
                    g_lastSnippetMatchTime = CFAbsoluteTimeGetCurrent();
                    hookLog([NSString stringWithFormat:@"Snippet match: '%@' → '%@'", captured, processed]);
                    @try {
                        [[NSDistributedNotificationCenter defaultCenter]
                            postNotificationName:@"Type4Me.DoubaoASRTextInserted"
                                          object:nil
                                        userInfo:@{
                                            @"rawText": captured,
                                            @"processedText": processed,
                                            @"charCount": @(captured.length)
                                        }
                                        deliverImmediately:YES];
                    } @catch (NSException *e) {
                        hookLog([NSString stringWithFormat:@"Notification error: %@", e]);
                    }
                } else {
                    hookLog([NSString stringWithFormat:@"Deduplicated: '%@'", [captured substringToIndex:MIN(captured.length, 20)]]);
                }
            }
        });
    }
}

__attribute__((constructor))
static void doubaoHookInit(void) {
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"DoubaoIme"]) return;

    hookLog([NSString stringWithFormat:@"=== DoubaoHook v6 TEST_LEVEL=%d (pid %d) ===",
             TEST_LEVEL, [[NSProcessInfo processInfo] processIdentifier]]);

    Class clientCls = NSClassFromString(@"_IPMDServerClientWrapperLegacy");
    if (!clientCls) { hookLog(@"ERROR: class not found"); return; }

    SEL sel = sel_registerName("insertText:replacementRange:validFlags:");
    Method method = class_getInstanceMethod(clientCls, sel);
    if (!method) { hookLog(@"ERROR: method not found"); return; }

    g_originalInsertTextWithFlags = method_getImplementation(method);
    method_setImplementation(method, (IMP)hooked_insertText_replacementRange_validFlags);

    // Also hook 2-param version with C function IMP (no block ABI issues)
    SEL sel2 = @selector(insertText:replacementRange:);
    Method method2 = class_getInstanceMethod(clientCls, sel2);
    if (method2) {
        g_originalInsertText2 = method_getImplementation(method2);
        method_setImplementation(method2, (IMP)hooked_insertText_replacementRange_2param);
        hookLog(@"Hooked 2-param insertText (block dups)");
    }

    // Preload snippets at init time (main thread, no concurrency issues)
    preloadSnippets();
    hookLog([NSString stringWithFormat:@"v6 ready (%lu snippet rules)", (unsigned long)(g_snippetRegexes ? g_snippetRegexes.count : 0)]);
}
