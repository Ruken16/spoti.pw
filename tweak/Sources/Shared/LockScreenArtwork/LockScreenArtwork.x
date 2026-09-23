// Spotify downloads a Canvas beside a playing track through canva[z]-cache.  The app normally only
// gives that video to its own player view.  iOS's animated-now-playing API is deliberately handed a
// local file, so retain the Canvas in the app cache and give the same file and its opening frame to
// the lock screen.  The original static Spotify cover stays in the dictionary as the fallback.
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "LockScreenArtwork.h"

static const NSUInteger kMaxCanvasBytes = 25 * 1024 * 1024;
static const NSUInteger kKeptCanvases = 12;

static char kCanvasBodyKey;
static NSObject *sg_lock;
// Full Spotify track URI -> the local MP4 that was returned for it.
static NSMutableDictionary<NSString *, NSURL *> *sg_canvasFiles;
// A media artwork has to outlive nowPlayingInfo, so retain every one still associated with a cached file.
static NSMutableDictionary<NSString *, id> *sg_artworks;
static NSMutableSet<NSString *> *sg_downloading;
static BOOL sg_writingNowPlaying;

static NSURLRequest *requestOf(NSURLSessionTask *task) {
    return task.currentRequest ?: task.originalRequest;
}

// The download URL is deliberately not accepted here: reading its video bytes through the delegate
// would retain a complete movie in memory.  We only collect the small metadata JSON from spclient.
static BOOL isCanvasMetadataRequest(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path.lowercaseString;
    return [host containsString:@"spclient"] && ([path containsString:@"canvaz-cache"] || [path containsString:@"/canvases"]);
}

static NSString *trackURIFromString(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    value = value.stringByRemovingPercentEncoding ?: value;
    NSRange start = [value rangeOfString:@"spotify:track:"];
    if (start.location == NSNotFound) return nil;
    NSString *tail = [value substringFromIndex:start.location];
    NSCharacterSet *end = [NSCharacterSet characterSetWithCharactersInString:@",&?/"];
    NSRange stop = [tail rangeOfCharacterFromSet:end options:0 range:NSMakeRange(@"spotify:track:".length, tail.length - @"spotify:track:".length)];
    return stop.location == NSNotFound ? tail : [tail substringToIndex:stop.location];
}

static NSString *requestedTrack(NSURL *url) {
    for (NSURLQueryItem *item in [[NSURLComponents alloc] initWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        NSString *track = trackURIFromString(item.value);
        if (track) return track;
    }
    return nil;
}

static NSString *trackInCanvas(NSDictionary *canvas, NSString *fallback) {
    for (NSString *key in @[@"track_uri", @"trackUri", @"track", @"uri"]) {
        NSString *track = trackURIFromString(canvas[key]);
        if (track) return track;
    }
    return fallback;
}

static NSURL *videoURLInCanvas(NSDictionary *canvas, BOOL inCanvasList) {
    NSArray<NSString *> *keys = inCanvasList
        ? @[@"canvas_url", @"canvasUrl", @"video_url", @"videoUrl", @"url"]
        : @[@"canvas_url", @"canvasUrl", @"video_url", @"videoUrl"];
    for (NSString *key in keys) {
        id value = canvas[key];
        if (![value isKindOfClass:NSString.class]) continue;
        NSURL *url = [NSURL URLWithString:value];
        if ([[url.scheme lowercaseString] isEqualToString:@"https"] && url.host.length) return url;
    }
    return nil;
}

static NSString *currentTrack(void) {
    NSString *track = SGURIString(SGPlayerState().track.URI);
    return trackURIFromString(track);
}

static NSURL *canvasDirectory(void) {
    NSURL *cache = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [cache URLByAppendingPathComponent:@"SpotifyGlass/Canvas" isDirectory:YES];
    NSError *error;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        SGLog(@"lock screen Canvas: could not make cache: %@", error);
        return nil;
    }
    return directory;
}

static NSString *fileName(NSString *track, NSURL *remote) {
    NSString *trackID = [track componentsSeparatedByString:@":"].lastObject ?: @"canvas";
    NSString *extension = remote.pathExtension.lowercaseString;
    if (![@[@"mp4", @"mov", @"m4v"] containsObject:extension]) extension = @"mp4";
    return [NSString stringWithFormat:@"%@-%08lx.%@", trackID, (unsigned long)remote.absoluteString.hash, extension];
}

// Keep the cache bounded without removing the Canvas that was just attached to now playing.
static void trimCache(NSURL *keeping) {
    NSURL *directory = canvasDirectory();
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
                                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                             options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    if (files.count <= kKeptCanvases) return;
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        NSDate *leftDate, *rightDate;
        [left getResourceValue:&leftDate forKey:NSURLContentModificationDateKey error:nil];
        [right getResourceValue:&rightDate forKey:NSURLContentModificationDateKey error:nil];
        return [leftDate compare:rightDate];
    }];
    for (NSURL *file in files) {
        if (files.count <= kKeptCanvases || [file isEqual:keeping]) continue;
        [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        files = [files subarrayWithRange:NSMakeRange(1, files.count - 1)];
    }
}

static UIImage *previewForFile(NSURL *file, CGSize size) API_AVAILABLE(ios(19.0));
static MPMediaItemAnimatedArtwork *artworkForFile(NSString *track, NSURL *file) API_AVAILABLE(ios(19.0));
static NSDictionary *withCanvasArtwork(NSDictionary *info) API_AVAILABLE(ios(19.0));

static void refreshNowPlayingForTrack(NSString *track) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![track isEqualToString:currentTrack()]) return;
        NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        if (!info) return;
        if (@available(iOS 26.0, *)) {
            sg_writingNowPlaying = YES;
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = withCanvasArtwork(info);
            sg_writingNowPlaying = NO;
        }
    });
}

static void keepCanvas(NSString *track, NSURL *file) {
    @synchronized (sg_lock) { sg_canvasFiles[track] = file; }
    trimCache(file);
    SGLog(@"lock screen Canvas: cached %@", track);
    refreshNowPlayingForTrack(track);
}

static void downloadCanvas(NSString *track, NSURL *remote) {
    if (!track || !remote) return;
    NSString *key = [NSString stringWithFormat:@"%@|%@", track, remote.absoluteString];
    @synchronized (sg_lock) {
        if ([sg_downloading containsObject:key]) return;
        [sg_downloading addObject:key];
    }
    NSURL *destination = [canvasDirectory() URLByAppendingPathComponent:fileName(track, remote)];
    if (!destination) {
        @synchronized (sg_lock) { [sg_downloading removeObject:key]; }
        return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        @synchronized (sg_lock) { [sg_downloading removeObject:key]; }
        keepCanvas(track, destination);
        return;
    }
    [[NSURLSession.sharedSession downloadTaskWithURL:remote completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
        @synchronized (sg_lock) { [sg_downloading removeObject:key]; }
        NSDictionary *attributes = temporary ? [NSFileManager.defaultManager attributesOfItemAtPath:temporary.path error:nil] : nil;
        unsigned long long bytes = [attributes[NSFileSize] unsignedLongLongValue];
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || status < 200 || status >= 300 || !bytes || bytes > kMaxCanvasBytes) {
            SGLog(@"lock screen Canvas: download for %@ failed (%@, status %ld, %llu bytes)", track, error, (long)status, bytes);
            return;
        }
        NSError *moveError;
        if (![NSFileManager.defaultManager moveItemAtURL:temporary toURL:destination error:&moveError]) {
            SGLog(@"lock screen Canvas: could not save %@: %@", track, moveError);
            return;
        }
        keepCanvas(track, destination);
    }] resume];
}

// The response shape has changed a few times (camel- and snake-case names); only a value inside a
// `canvases` list is allowed to use the generic `url` field, so unrelated URLs are never downloaded.
static void collectCanvases(id object, NSString *requested, BOOL inCanvasList) {
    if ([object isKindOfClass:NSArray.class]) {
        for (id item in object) collectCanvases(item, requested, inCanvasList);
        return;
    }
    if (![object isKindOfClass:NSDictionary.class]) return;
    NSDictionary *canvas = object;
    NSString *track = trackInCanvas(canvas, requested);
    NSURL *video = videoURLInCanvas(canvas, inCanvasList);
    if (track && video) downloadCanvas(track, video);
    [canvas enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        BOOL childIsCanvasList = inCanvasList || ([key isKindOfClass:NSString.class] && [[(NSString *)key lowercaseString] containsString:@"canva"]);
        collectCanvases(value, track, childIsCanvasList);
    }];
}

static void received(NSURLSessionTask *task, NSData *data) {
    NSURL *url = requestOf(task).URL;
    if (!isCanvasMetadataRequest(url)) return;
    NSMutableData *body = objc_getAssociatedObject(task, &kCanvasBodyKey);
    if (!body) objc_setAssociatedObject(task, &kCanvasBodyKey, (body = [NSMutableData data]), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // A Canvas index is tiny.  Give up instead of retaining arbitrary response data if Spotify changes an endpoint.
    if (body.length + data.length > 512 * 1024) {
        objc_setAssociatedObject(task, &kCanvasBodyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    [body appendData:data];
}

static void completed(NSURLSessionTask *task, NSError *error) {
    NSMutableData *body = objc_getAssociatedObject(task, &kCanvasBodyKey);
    if (!body) return;
    objc_setAssociatedObject(task, &kCanvasBodyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *track = requestedTrack(requestOf(task).URL);
    if (error || !track) return;
    NSError *jsonError;
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:&jsonError];
    if (!json) {
        SGLog(@"lock screen Canvas: index for %@ was not JSON: %@", track, jsonError);
        return;
    }
    collectCanvases(json, track, NO);
}

static UIImage *previewForFile(NSURL *file, CGSize size) {
    AVAssetImageGenerator *generator = [[AVAssetImageGenerator alloc] initWithAsset:[AVURLAsset URLAssetWithURL:file options:nil]];
    generator.appliesPreferredTrackTransform = YES;
    if (size.width > 0 && size.height > 0) generator.maximumSize = size;
    NSError *error;
    CGImageRef frame = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600) actualTime:nil error:&error];
    if (!frame) {
        SGLog(@"lock screen Canvas: could not read preview %@: %@", file.lastPathComponent, error);
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:frame];
    CGImageRelease(frame);
    return image;
}

static NSString *artworkKeyForFile(NSURL *file) API_AVAILABLE(ios(19.0));
static NSString *artworkKeyForFile(NSURL *file) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    AVAssetTrack *video = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!video) return nil;
    CGRect rect = CGRectApplyAffineTransform((CGRect){ .size = video.naturalSize }, video.preferredTransform);
    CGFloat width = fabs(rect.size.width), height = fabs(rect.size.height);
    CGFloat aspect = height ? width / height : 0;
    // Spotify Canvas is normally portrait.  The system's tall slot is the closest supported one;
    // square Canvas uses the square slot so it is not stretched by the lock screen.
    return aspect > 0.88 && aspect < 1.12 ? MPNowPlayingInfoProperty1x1AnimatedArtwork : MPNowPlayingInfoProperty3x4AnimatedArtwork;
}

static MPMediaItemAnimatedArtwork *artworkForFile(NSString *track, NSURL *file) {
    if (!file.isFileURL || ![NSFileManager.defaultManager fileExistsAtPath:file.path]) return nil;
    @synchronized (sg_lock) {
        MPMediaItemAnimatedArtwork *artwork = sg_artworks[file.path];
        if (artwork) return artwork;
        NSString *artworkID = [NSString stringWithFormat:@"%@|%@", track, file.lastPathComponent];
        artwork = [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
            previewImageRequestHandler:^(CGSize size, void (^completion)(UIImage *image)) {
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    completion(previewForFile(file, size));
                });
            }
            videoAssetFileURLRequestHandler:^(CGSize size, void (^completion)(NSURL *url)) {
                completion([NSFileManager.defaultManager fileExistsAtPath:file.path] ? file : nil);
            }];
        sg_artworks[file.path] = artwork;
        return artwork;
    }
}

static NSDictionary *withCanvasArtwork(NSDictionary *info) {
    if (!info) return info;
    NSString *track = currentTrack();
    NSURL *file;
    @synchronized (sg_lock) { file = sg_canvasFiles[track]; }
    if (!track || !file) return info;
    NSString *key = artworkKeyForFile(file);
    if (!key || ![MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys containsObject:key] || info[key]) return info;
    MPMediaItemAnimatedArtwork *artwork = artworkForFile(track, file);
    if (!artwork) return info;
    NSMutableDictionary *withArtwork = [info mutableCopy];
    withArtwork[key] = artwork;
    return withArtwork;
}

%group LockScreenCanvasHooks
%hook SPTDataLoaderService
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    received(task, data);
    %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(task, error);
    %orig;
}
%end

%hook _TtC26Connectivity_HttpClientKit20HttpClientURLSession
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    received(task, data);
    %orig;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    completed(task, error);
    %orig;
}
%end

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    NSDictionary *out = info;
    if (!sg_writingNowPlaying) {
        if (@available(iOS 26.0, *)) out = withCanvasArtwork(info);
    }
    %orig(out);
}
%end
%end

%ctor {
    if (!SGFlag(SGKeyLockScreenCanvas, YES)) return;
    if (@available(iOS 26.0, *)) {
        // The class and its now-playing keys exist on this system.  Keep initialization below the
        // positive availability check so older iOS releases never resolve those newer symbols.
    } else {
        SGLog(@"lock screen Canvas: needs iOS 26 or newer");
        return;
    }
    sg_lock = [NSObject new];
    sg_canvasFiles = [NSMutableDictionary dictionary];
    sg_artworks = [NSMutableDictionary dictionary];
    sg_downloading = [NSMutableSet set];
    %init(LockScreenCanvasHooks);
    SGRequireClasses(@[@"SPTDataLoaderService", @"_TtC26Connectivity_HttpClientKit20HttpClientURLSession", @"MPNowPlayingInfoCenter"]);
    SGLog(@"lock screen Canvas: on");
}
