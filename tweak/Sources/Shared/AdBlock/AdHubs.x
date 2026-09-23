// Home, Browse and Search arrive as Hub JSON. Sponsored components are removed before Spotify's
// builder turns them into views; textual titles are deliberately not inspected ("Billboard Hot
// 100", for example, is a legitimate playlist rather than an advertisement).
#import "Core/SGCore.h"
#import "AdBlock.h"

static NSString *const adWords[] = {
    @"sponsored", @"campaign", @"promoted", @"billboard", @"interstitial", @"marquee",
    @"leavebehind", @"leave-behind", @"displayad", @"display-ad", @"fullbleed", @"full-bleed",
    @"leaderboard", @"advertisement", @"sponsor", @"native-ad", @"mobile-ads", @"on-surface",
    @"onsurface", @"search-ad", @"home-ad", @"sponsored-content", @"sponsored-ad", @"ad-card",
    @"native-ad-home-shelf", @"sponsored-shelf", @"sponsored-row", @"ad-shelf", @"ad-row",
    @"sponsored-item", @"ad-item", @"mobile-display-ad-card", @"mobile-ads-display-ad-element",
};

#define COUNT(list) (sizeof(list) / sizeof(list[0]))

static BOOL containsAdWord(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NO;
    text = text.lowercaseString;
    for (size_t i = 0; i < COUNT(adWords); i++) {
        if ([text containsString:adWords[i]]) return YES;
    }
    return NO;
}

static BOOL dictionaryHasAdKey(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in dictionary) {
        if (containsAdWord(key)) return YES;
    }
    return NO;
}

static BOOL isAd(NSDictionary *component) {
    id kind = component[@"component"];
    if ([kind isKindOfClass:NSDictionary.class]) {
        NSString *ns = kind[@"namespace"], *name = kind[@"name"];
        if (containsAdWord(ns) || containsAdWord(name)
            || containsAdWord([NSString stringWithFormat:@"%@:%@", ns ?: @"", name ?: @""])) return YES;
    } else if (containsAdWord(kind)) {
        return YES;
    }
    if (containsAdWord(component[@"id"]) || containsAdWord(component[@"type"])) return YES;
    NSDictionary *metadata = component[@"metadata"];
    for (NSString *key in @[@"ad", @"is_ad", @"is_sponsored"]) {
        if ([metadata[key] respondsToSelector:@selector(boolValue)] && [metadata[key] boolValue]) return YES;
    }
    if (dictionaryHasAdKey(metadata) || dictionaryHasAdKey(component[@"custom"])) return YES;
    NSDictionary *logging = component[@"logging"];
    return [logging isKindOfClass:NSDictionary.class]
        && (containsAdWord(logging[@"type"]) || dictionaryHasAdKey(logging));
}

static NSArray *filtered(NSArray *components) {
    if (![components isKindOfClass:NSArray.class]) return components;
    NSMutableArray *kept = [NSMutableArray array];
    for (NSDictionary *component in components) {
        if (![component isKindOfClass:NSDictionary.class]) {
            [kept addObject:component];
            continue;
        }
        if (isAd(component)) {
            SGAdBlockCountOne(@"Page components");
            SGLog(@"ad block: dropped Hub component %@", component[@"id"] ?: component[@"component"]);
            continue;
        }
        NSMutableDictionary *copy = [component mutableCopy];
        for (NSString *key in @[@"children", @"rows", @"body"]) {
            if (copy[key]) copy[key] = filtered(copy[key]);
        }
        [kept addObject:copy];
    }
    return kept;
}

%hook HUBViewModelBuilderImplementation
- (void)addJSONDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:NSDictionary.class]) {
        %orig;
        return;
    }
    NSMutableDictionary *copy = [dictionary mutableCopy];
    for (NSString *key in @[@"body", @"overlays", @"sections"]) {
        if (copy[key]) copy[key] = filtered(copy[key]);
    }
    NSDictionary *header = copy[@"header"];
    if (isAd(header)) {
        SGAdBlockCountOne(@"Page components");
        [copy removeObjectForKey:@"header"];
    } else if (header[@"children"]) {
        NSMutableDictionary *headerCopy = [header mutableCopy];
        headerCopy[@"children"] = filtered(header[@"children"]);
        copy[@"header"] = headerCopy;
    }
    %orig(copy);
}
%end

%ctor {
    if (!SGEnabled(SGKeyBlockAds)) return;
    %init;
    SGRequireClasses(@[@"HUBViewModelBuilderImplementation"]);
}
