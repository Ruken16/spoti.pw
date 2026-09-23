// Advertising services in Spotify 9.1.78. Keeping their -load / registration calls empty prevents
// the corresponding surface from being wired up. This is the ad-only subset of the earlier
// EeveeSpotify-derived integration: upsells and Premium entitlement changes are not included.
#import "Core/SGCore.h"
#import "AdBlock.h"

static void takeDown(id object) {
    if (![object isKindOfClass:UIView.class]) return;
    UIView *view = object;
    view.hidden = YES;
    view.userInteractionEnabled = NO;
    if (view.superview) [view removeFromSuperview];
}

%hook _TtC19AdsPlatform_AdsImpl14AdsServiceImpl
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC29AdsNowPlaying_InStreamAdsImpl18InStreamAdsService
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC29AdsNowPlaying_EmbeddedNPVImpl22EmbeddedNPVServiceImpl
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC36AdsStandalone_LeavebehindAdsBaseImpl25LeavebehindAdsBaseService
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC36AdsStandalone_LeavebehindAdsBaseImpl33LeavebehindAdsBaseInternalService
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC35AdsEmbedded_AdsSponsoredContextImpl30AdsSponsoredContextServiceImpl
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC48AdsEmbedded_AdsSponsoredContextNPBAttachmentImpl43AdsSponsoredContextNPBAttachmentServiceImpl
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC42AdsEmbedded_AdsSponsoredPlaylistHeaderImpl37AdsSponsoredPlaylistHeaderServiceImpl
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

%hook _TtC20NativeAds_LoggerImpl26NativeAdsLoggerServiceImpl
- (void)load { SGAdBlockCountOne(@"Ad services"); }
%end

// The leave-behind card among the player's scroll cards is registered rather than loaded.
%hook _TtC32AdsEmbedded_EmbeddedCTACardsImpl23EmbeddedCTACardsService
- (void)registerScrollProviderIn:(id)registry { SGAdBlockCountOne(@"Ad services"); }
%end

// A view fallback covers a sponsored header already materialized before the service hook runs.
%hook _TtC18AdsPlatform_ECMKit37AdsSponsoredPlaylistHeaderCentralView
- (void)didMoveToSuperview {
    %orig;
    takeDown(self);
}
%end

%ctor {
    if (!SGEnabled(SGKeyBlockAds)) return;
    %init;
    SGRequireClasses(@[
        @"_TtC19AdsPlatform_AdsImpl14AdsServiceImpl",
        @"_TtC29AdsNowPlaying_InStreamAdsImpl18InStreamAdsService",
        @"_TtC29AdsNowPlaying_EmbeddedNPVImpl22EmbeddedNPVServiceImpl",
        @"_TtC36AdsStandalone_LeavebehindAdsBaseImpl25LeavebehindAdsBaseService",
        @"_TtC36AdsStandalone_LeavebehindAdsBaseImpl33LeavebehindAdsBaseInternalService",
        @"_TtC35AdsEmbedded_AdsSponsoredContextImpl30AdsSponsoredContextServiceImpl",
        @"_TtC48AdsEmbedded_AdsSponsoredContextNPBAttachmentImpl43AdsSponsoredContextNPBAttachmentServiceImpl",
        @"_TtC42AdsEmbedded_AdsSponsoredPlaylistHeaderImpl37AdsSponsoredPlaylistHeaderServiceImpl",
        @"_TtC20NativeAds_LoggerImpl26NativeAdsLoggerServiceImpl",
        @"_TtC32AdsEmbedded_EmbeddedCTACardsImpl23EmbeddedCTACardsService",
        @"_TtC18AdsPlatform_ECMKit37AdsSponsoredPlaylistHeaderCentralView",
    ]);
}
