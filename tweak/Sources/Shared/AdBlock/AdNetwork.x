// Requests that have no UI service still arrive through Spotify's two URLSession delegates. Ad
// endpoints receive an empty body; browsita, casita and scrollsita replies are held until their
// sponsored feed sections can be removed and then delivered through Spotify's original delegate.
#import "Core/SGCore.h"
#import "AdBlock.h"

static char kBufferKey, kPassKey;

typedef NS_ENUM(NSInteger, SGAdNet) { SGAdNetPass, SGAdNetBlock, SGAdNetFilterFeed };

static BOOL has(NSString *text, NSString *needle) {
    return [text containsString:needle];
}

static BOOL isFeed(NSString *path) {
    // casita/v1/feeds is the tab-chip list, rather than a section feed.
    if (has(path, @"/casita/v1/feeds")) return NO;
    return has(path, @"/browsita/") || has(path, @"/casita/") || has(path, @"/scrollsita/");
}

static NSString *const adPaths[] = {
    @"/ads/", @"/ad-logic/", @"/dac/view/v1/", @"/ad-slot/", @"/ad-inventory/", @"/ad-on-app-open",
    @"/sponsored/", @"/promoted/", @"/search-ad/", @"/home-ad/", @"/marquee/", @"/leavebehind",
    @"/leave-behind", @"/display-ad/", @"/fullbleed/", @"/leaderboard/", @"/ad-card/",
    @"/sponsored-content/", @"/sponsored-ad/", @"/native-ad/", @"/sponsored-shelf/", @"/sponsored-row/",
    @"/ad-shelf/", @"/ad-row/", @"/sponsored-item/", @"/ad-item/", @"/home-ads/", @"/search-ads/",
};

static BOOL isAd(NSURL *url, NSString *path) {
    for (size_t i = 0; i < sizeof(adPaths) / sizeof(adPaths[0]); i++) {
        if (has(path, adPaths[i])) return YES;
    }
    if (has(path, @"/esperanto/") && (has(path, @"ad") || has(path, @"slot"))) return YES;
    NSString *host = url.host.lowercaseString ?: @"";
    return has(host, @"doubleclick") || has(host, @"googlesyndication") || [host hasPrefix:@"aet."]
        || [@[@"ad.spotify.com", @"ads.spotify.com", @"aet.spotify.com"] containsObject:host];
}

static SGAdNet classify(NSURL *url) {
    if (!url) return SGAdNetPass;
    NSString *path = url.path.lowercaseString ?: @"";
    if (isAd(url, path)) return SGAdNetBlock;
    return isFeed(path) ? SGAdNetFilterFeed : SGAdNetPass;
}

// A data delivered by this hook must bypass its own didReceiveData interception.
static void deliver(id<NSURLSessionDataDelegate> delegate, NSURLSession *session, NSURLSessionTask *task, NSData *data) {
    objc_setAssociatedObject(task, &kPassKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [delegate URLSession:session dataTask:(NSURLSessionDataTask *)task didReceiveData:data];
    objc_setAssociatedObject(task, &kPassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL holds(NSURLSessionTask *task, NSData *data) {
    if (objc_getAssociatedObject(task, &kPassKey)) return NO;
    switch (classify(task.currentRequest.URL)) {
        case SGAdNetBlock:
            return YES;
        case SGAdNetFilterFeed: {
            NSMutableData *buffer = objc_getAssociatedObject(task, &kBufferKey);
            if (!buffer) {
                buffer = [NSMutableData data];
                objc_setAssociatedObject(task, &kBufferKey, buffer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            [buffer appendData:data];
            return YES;
        }
        case SGAdNetPass:
            return NO;
    }
    return NO;
}

static void complete(id<NSURLSessionDataDelegate> delegate, NSURLSession *session, NSURLSessionTask *task,
                     NSError *error, void (^finish)(NSError *)) {
    NSURL *url = task.currentRequest.URL;
    NSString *path = url.path.lowercaseString ?: @"";
    NSMutableData *buffer = objc_getAssociatedObject(task, &kBufferKey);
    objc_setAssociatedObject(task, &kBufferKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    switch (classify(url)) {
        case SGAdNetBlock:
            SGAdBlockCountOne(@"Network requests");
            SGLog(@"ad block: answered %@ empty", path);
            deliver(delegate, session, task, NSData.data);
            finish(nil);
            return;
        case SGAdNetFilterFeed:
            if (error) {
                finish(error);
                return;
            }
            // An empty body still needs a delegate delivery; otherwise some readers remain pending.
            deliver(delegate, session, task, buffer ? (SGStripAdSections(buffer) ?: buffer) : NSData.data);
            finish(nil);
            return;
        case SGAdNetPass:
            finish(error);
            return;
    }
}

%hook SPTDataLoaderService
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!holds(task, data)) %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    complete((id)self, session, task, error, ^(NSError *passed) { %orig(session, task, passed); });
}
%end

%hook _TtC26Connectivity_HttpClientKit20HttpClientURLSession
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (!holds(task, data)) %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    complete((id)self, session, task, error, ^(NSError *passed) { %orig(session, task, passed); });
}
%end

%ctor {
    if (!SGEnabled(SGKeyBlockAds)) return;
    %init;
    SGRequireClasses(@[@"SPTDataLoaderService", @"_TtC26Connectivity_HttpClientKit20HttpClientURLSession"]);
}
