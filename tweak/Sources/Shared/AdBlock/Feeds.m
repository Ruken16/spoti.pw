// The Home, Search and player feeds are protobuf containers of sections. The scanner only removes
// sections with structural advertising markers; it never reads titles or ordinary music metadata.
#import "Core/SGCore.h"
#import "AdBlock.h"
#import "Shared/Lyrics/Protobuf.h"

static const char *const adMarkers[] = {
    "spotify:ad:", "ad-formats", "advertisement", "brand-ad", "sponsored", "marquee", "promoted",
    "home-ads", "adsproduct", "leavebehind", "leave-behind",
};

#define COUNT(list) (sizeof(list) / sizeof(list[0]))

static BOOL contains(NSData *data, const char *needle) {
    const uint8_t *bytes = data.bytes;
    size_t length = data.length, needleLength = strlen(needle);
    for (size_t i = 0; i + needleLength <= length; i++) {
        size_t k = 0;
        while (k < needleLength && tolower(bytes[i + k]) == needle[k]) k++;
        if (k == needleLength) return YES;
    }
    return NO;
}

static BOOL adSection(NSData *section) {
    for (size_t i = 0; i < COUNT(adMarkers); i++) {
        if (contains(section, adMarkers[i])) return YES;
    }
    return NO;
}

NSData *SGStripAdSections(NSData *body) {
    NSMutableArray<SGPBField *> *fields = SGPBParse(body);
    SGPBField *container = fields.firstObject;
    if (container.number != 1 || container.wire != 2) return nil;
    NSMutableArray<SGPBField *> *sections = SGPBParse(container.payload);
    if (!sections) return nil;
    NSMutableArray<SGPBField *> *kept = [NSMutableArray array];
    for (SGPBField *section in sections) {
        if (section.number != 1 || section.wire != 2) return nil;
        if (adSection(section.payload)) SGAdBlockCountOne(@"Feed sections");
        else [kept addObject:section];
    }
    if (kept.count == sections.count) return nil;
    SGLog(@"ad block: dropped %lu of %lu feed sections", (unsigned long)(sections.count - kept.count),
          (unsigned long)sections.count);
    container.payload = SGPBSerialize(kept);
    return SGPBSerialize(fields);
}
