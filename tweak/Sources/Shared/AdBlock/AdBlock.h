// Ad blocking is deliberately separate from Premium state: it prevents the app from loading,
// rendering and fetching advertising, without changing the account Spotify reports to the user.
#import <UIKit/UIKit.h>

// A regular switch rather than a hide switch: it starts on for a new install and Reset all settings
// turns it off together with every other mod feature.
#define SGKeyBlockAds @"spotifyglass.adblock.enabled"

// AdBlock.m registers this with Core/SGFlagForce so the flag provider and the All flags page see
// the ad surfaces as forced off while blocking is active.
BOOL SGAdBlockForcesFlagOff(NSString *key);

// The settings page reports what each layer stopped. Hooks can run on background queues.
void SGAdBlockCountOne(NSString *label);
NSArray<NSString *> *SGAdBlockLabels(void);
NSUInteger SGAdBlockCount(NSString *label);
void SGResetAdBlock(void);

// Feeds.m removes sponsored sections from the protobuf feeds that make Home, Search and the
// player scroll cards. nil means the response was not a feed shape we recognize or had no ads.
NSData *SGStripAdSections(NSData *body);
