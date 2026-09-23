#import "Core/SGCore.h"
#import "AdBlock.h"

#pragma mark - Remote configuration

// These are the ad flags present in Spotify 9.1.78. They only prevent ad surfaces from being
// constructed; account and entitlement flags are intentionally left to Spotify.
static NSString *const adFlags[] = {
    @"ios-feature-adonappopen.enabled",
    @"ios-feature-adonappopen.cta_card_enabled",
    @"ios-nowplaying-scroll-impl.unified_leavebehind_npv_scroll_music_enabled",
    @"ios-nowplaying-scroll-impl.unified_leavebehind_npv_scroll_podcast_enabled",
    @"ios-feature-embeddedplaylist.use_unified_leavebehind_fetch",
    @"ios-adsnowplaying-embeddednpv-impl.foreground_enabled",
    @"ios-adsnowplaying-embeddednpv-impl.music_track_change_enabled",
    @"ios-adsnowplaying-embeddednpv-impl.enable_ads_on_podcast",
    @"ios-feature-adsbase.enable_ads_connect_state_observer",
    @"ios-feature-adsbase.enable_minimal_preroll_management",
    @"ios-feature-adsnowplayingui.embedded_npv_video_show_with_canvas",
    @"ios-feature-adssponsoredcontext.sponsored_playlist_v2_enabled",
    @"ios-feature-adssponsoredcontext.sponsored_context_mismatch_aderror_enabled",
    @"ios-feature-adssponsoredcontextnpbattachment.sponsored_npb_slot_fetch_enabled",
};

BOOL SGAdBlockForcesFlagOff(NSString *key) {
    if (!SGEnabled(SGKeyBlockAds)) return NO;
    for (size_t i = 0; i < sizeof(adFlags) / sizeof(adFlags[0]); i++) {
        if ([key isEqualToString:adFlags[i]]) return YES;
    }
    return NO;
}

// Put the ad rule after the redesign's rules but before a user override, as the configuration
// provider expects all forced flags to be registered at load time.
__attribute__((constructor)) static void registerForcer(void) {
    SGFlagForcer off = ^id(NSString *key) { return SGAdBlockForcesFlagOff(key) ? @NO : nil; };
    SGRegisterFlagForcer(NO, off, off);
}

#pragma mark - Counters

static NSString *const kCounts = @"spotifyglass.adblock.counts";
static NSString *const labels[] = {
    @"Ad services", @"Page components", @"Feed sections", @"Network requests",
};
static NSMutableDictionary<NSString *, NSNumber *> *sg_counts;

static NSMutableDictionary<NSString *, NSNumber *> *countsLocked(void) {
    if (!sg_counts) {
        sg_counts = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kCounts] mutableCopy]
            ?: [NSMutableDictionary dictionary];
    }
    return sg_counts;
}

void SGAdBlockCountOne(NSString *label) {
    @synchronized (kCounts) {
        NSMutableDictionary<NSString *, NSNumber *> *counts = countsLocked();
        counts[label] = @(counts[label].unsignedIntegerValue + 1);
        [NSUserDefaults.standardUserDefaults setObject:counts forKey:kCounts];
    }
}

NSArray<NSString *> *SGAdBlockLabels(void) {
    return [NSArray arrayWithObjects:labels count:sizeof(labels) / sizeof(labels[0])];
}

NSUInteger SGAdBlockCount(NSString *label) {
    @synchronized (kCounts) {
        NSDictionary<NSString *, NSNumber *> *counts = countsLocked();
        if (label) return counts[label].unsignedIntegerValue;
        NSUInteger total = 0;
        for (NSNumber *count in counts.allValues) total += count.unsignedIntegerValue;
        return total;
    }
}

void SGResetAdBlock(void) {
    @synchronized (kCounts) {
        sg_counts = [NSMutableDictionary dictionary];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kCounts];
    }
}
