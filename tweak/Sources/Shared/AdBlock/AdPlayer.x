// The player asks its own ad product state before opening the in-stream path. This targeted answer
// complements the service hook: it disables client-side ad playback without modifying the broader
// product state or presenting the account as Premium.
#import "Core/SGCore.h"
#import "AdBlock.h"

%hook SPTAdsProductState
- (BOOL)adsEnabled { return NO; }
%end

%ctor {
    if (!SGEnabled(SGKeyBlockAds)) return;
    %init;
    SGRequireClasses(@[@"SPTAdsProductState"]);
}
