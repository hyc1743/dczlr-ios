#import "DCEditScene.h"
#import "DCArchive.h"
#import "DCStartupScene.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#include "dc_config.h"
#include <math.h>
#include <string.h>

static BOOL editHit(float x, float y, float rx, float ry, float w, float h) {
    return x >= rx && x <= rx + w && y >= ry && y <= ry + h;
}

static const char *const kComboNames[10] = {
    "manaka", "yuko", "aoi",
    "mana_man", "yuko_man", "aoi_man",
    "mana_yuko", "yuko_aoi", "aoi_mana",
    "ma_yu_ao"
};

static const char *const kMapNames[8] = {
    "station", "train", "toilet", "hotel",
    "roadside", "park_hiru", "park_yoru", "mana_room"
};

static const char *const kPersonalityNames[3] = {
    "teiko", "jujun", "seido"
};

static const char *const kPregnancyNames[6] = {
    "futu", "seiri", "kiken", "jusei", "ninsin", "bote"
};

static const char *const kBadgeNames[9] = {
    "tijoku", "koukan", "ingo",
    "kouin", "sein", "seiuke",
    "seiyoku", "roshutu", "aokan"
};

static const char *const kSpeedNames[3] = {
    "osoi", "futu", "hayai"
};

static const float kSpeedBtnX[3] = { 664.f, 592.f, 520.f };

static const float kKeypadX[11] = {
    520.f, 520.f, 592.f, 664.f, 520.f, 592.f, 664.f, 520.f, 592.f, 664.f, 664.f
};
static const float kKeypadY[11] = {
    576.f, 536.f, 536.f, 536.f, 496.f, 496.f, 496.f, 456.f, 456.f, 456.f, 576.f
};

static const char *const kHeroineNames[3] = {
    "aoi", "yuko", "manaka"
};
static const float kHeroineBtnX[3] = { 904.f, 832.f, 760.f };

static const char *const kHoleNames[2] = {
    "seiki", "anaru"
};
static const float kHoleBtnX[2] = { 832.f, 904.f };

static const char *const kStripNames[8] = {
    "uwagi", "bura", "skirt", "pants", "kutu", "kami", "megane", "neco"
};
static const float kStripBtnX[8] = {
    760.f, 832.f, 760.f, 832.f, 904.f, 904.f, 832.f, 760.f
};
static const float kStripBtnY[8] = {
    496.f, 496.f, 536.f, 536.f, 536.f, 576.f, 576.f, 576.f
};

@implementation DCEditScene {
    dc_vk_sprite *_renderer;
    DCStartupScene *_transition;
    NSString *_directory;
    NSString *_captureName;
    NSDictionary *_lastRenderCapture;
    DCArchive *_archive;
    NSMutableDictionary<NSString *, NSNumber *> *_entryIndices;
    NSMutableDictionary<NSString *, NSNumber *> *_textures;
    NSMutableDictionary<NSString *, NSNumber *> *_textTextures;
    AVAudioPlayer *_select;
    AVAudioPlayer *_toggle;
    dc_edit_state _state;
    uint8_t _prevTab;
    uint8_t _uiCautionKind; /* 0=none, 1=Load browser, 2=Title/Quit */
    uint32_t _pendingAction;
    uint32_t _action;
    BOOL _entered;
    BOOL _ready;
    BOOL _draggingPlaylistThumb;
    BOOL _draggingFileThumb;
    NSMutableArray<NSDictionary *> *_editFiles;
    uint32_t _selectedFileIndex;
    uint32_t _fileScroll;
}

- (uint32_t)action { return _action; }
- (const dc_edit_state *)editState { return &_state; }
- (NSDictionary *)lastRenderCapture { return _lastRenderCapture; }

- (NSString *)presentationContext {
    return [NSString stringWithFormat:@"system=edit ready=%d tab=%u combo=%u map=%u steps=%u sel=%u pending=%u action=%u",
            _ready, _state.tab, _state.combo_idx, _state.map_idx, _state.step_count,
            _state.selected_step, _pendingAction, _action];
}

- (void)requestRenderCapture:(NSString *)name {
    _captureName = [name copy];
}

- (NSString *)writableStateDirectory {
    NSString *bundlePath = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSString *stdDir = _directory.stringByStandardizingPath;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (stdDir.length && (!bundlePath.length || ![stdDir hasPrefix:bundlePath]) && [fm isWritableFileAtPath:stdDir]) {
        return _directory;
    }
    NSString *docsRoot = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docsRoot.length) {
        NSString *writable = [docsRoot stringByAppendingPathComponent:@"game/Data"];
        [fm createDirectoryAtPath:writable withIntermediateDirectories:YES attributes:nil error:nil];
        return writable;
    }
    return _directory ?: @"";
}

- (NSString *)readableStatePath:(NSString *)relativePath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *writable = [[self writableStateDirectory] stringByAppendingPathComponent:relativePath];
    if (writable.length && [fm fileExistsAtPath:writable]) return writable;
    NSString *direct = [_directory stringByAppendingPathComponent:relativePath];
    if (direct.length && [fm fileExistsAtPath:direct]) return direct;
    return writable.length ? writable : direct;
}

- (AVAudioPlayer *)audio:(NSString *)name archive:(NSString *)file error:(NSString **)error {
    NSError *reason = nil;
    DCArchive *archive = [[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:file]] error:&reason];
    if (!archive) {
        if (error) *error = reason.localizedDescription;
        return nil;
    }
    for (uint32_t i = 0; i < archive.entryCount; ++i) {
        if ([[archive asciiNameAtIndex:i] caseInsensitiveCompare:name] == NSOrderedSame) {
            NSData *data = [archive readEntryAtIndex:i limit:32 * 1024 * 1024 error:&reason];
            AVAudioPlayer *player = data ? [[AVAudioPlayer alloc] initWithData:data error:&reason] : nil;
            if (!player || ![player prepareToPlay]) {
                if (error) *error = reason.localizedDescription ?: @"Edit audio preparation failed";
                return nil;
            }
            return player;
        }
    }
    if (error) *error = [NSString stringWithFormat:@"Missing original edit audio %@", name];
    return nil;
}

- (void)updateVolumes {
    NSData *configuration = [NSData dataWithContentsOfFile:[self readableStatePath:@"gcd.cfg"]];
    float se = -1200.f;
    dc_config cfg;
    if (configuration && dc_config_decode(configuration.bytes, configuration.length, &cfg) == DC_OK) {
        dc_config_slider_value(&cfg, 2, &se);
    }
    float vol = powf(10.f, se / 2000.f);
    if (_select) _select.volume = vol;
    if (_toggle) _toggle.volume = vol;
}

- (void)playSelect {
    if (_select) { _select.currentTime = 0; [_select play]; }
}

- (void)playToggle {
    if (_toggle) { _toggle.currentTime = 0; [_toggle play]; }
}

- (instancetype)initWithDirectory:(NSString *)directory
                         renderer:(dc_vk_sprite *)renderer
                       transition:(DCStartupScene *)transition
                            error:(NSString **)error {
    if (!(self = [super init])) return nil;
    _directory = [directory copy];
    _transition = transition;
    _textures = [NSMutableDictionary dictionary];
    _textTextures = [NSMutableDictionary dictionary];
    _editFiles = [NSMutableArray array];
    if (dc_edit_init(&_state) != DC_OK) {
        if (error) *error = @"Edit Studio state initialization failed";
        return nil;
    }
    _prevTab = DC_EDIT_TAB_CHARA;
    NSString *attachError = [self attachRenderer:renderer];
    if (attachError) {
        if (error) *error = attachError;
        return nil;
    }
    _select = [self audio:@"se100.wav" archive:@"RPP_14.pp" error:error];
    _toggle = [self audio:@"se101.wav" archive:@"RPP_14.pp" error:error];
    if (!_select || !_toggle) return nil;
    [self updateVolumes];
    [self refreshEditFiles];
    return self;
}

- (uintptr_t)textureNamed:(NSString *)name {
    if (!_renderer || !name.length) return 0;
    NSString *key = name.lowercaseString;
    NSNumber *cached = _textures[key];
    if (cached) return (uintptr_t)cached.unsignedLongLongValue;
    NSNumber *idx = _entryIndices[key];
    if (!idx || !_archive) return 0;
    NSError *reason = nil;
    DCDecodedImage *image = [_archive decodeImageAtIndex:idx.unsignedIntValue
                                              inputLimit:8 * 1024 * 1024
                                             outputLimit:64 * 1024 * 1024
                                                   error:&reason];
    uintptr_t handle = 0;
    if (!image || dc_vk_sprite_upload(_renderer, image.width, image.height,
                                      image.rgba.bytes, image.rgba.length, &handle) != DC_OK) {
        return 0;
    }
    _textures[key] = @((unsigned long long)handle);
    return handle;
}

- (uintptr_t)textTextureForKey:(NSString *)key text:(NSString *)text width:(uint32_t)w height:(uint32_t)h {
    if (!_renderer || !key.length || !w || !h) return 0;
    NSNumber *cached = _textTextures[key];
    if (cached) return (uintptr_t)cached.unsignedLongLongValue;
    size_t rowBytes = (size_t)w * 4u;
    size_t totalBytes = rowBytes * (size_t)h;
    uint8_t *pixels = calloc(1, totalBytes);
    if (!pixels) return 0;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, rowBytes, cs,
                                             kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
    if (ctx && text.length) {
        CGContextSetAllowsAntialiasing(ctx, true);
        CGContextSetShouldAntialias(ctx, true);
        CTFontRef font = CTFontCreateWithName(CFSTR("HiraginoSans-W6"), 20.0, NULL);
        if (!font) font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 20.0, NULL);
        CGFloat rgba[4] = { 1.0, 1.0, 1.0, 1.0 };
        CGColorRef white = CGColorCreate(cs, rgba);
        if (font && white) {
            CFStringRef keys[2] = { kCTFontAttributeName, kCTForegroundColorAttributeName };
            CFTypeRef vals[2] = { font, white };
            CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault,
                                                       (const void **)keys, (const void **)vals, 2,
                                                       &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
            if (attrs) {
                CFAttributedStringRef astr = CFAttributedStringCreate(kCFAllocatorDefault,
                                                                      (__bridge CFStringRef)text, attrs);
                if (astr) {
                    CTLineRef line = CTLineCreateWithAttributedString(astr);
                    if (line) {
                        CGFloat ascent = 0, descent = 0, leading = 0;
                        CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
                        CGFloat baselineY = floor(((CGFloat)h - (ascent + descent)) * 0.5 + descent);
                        CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
                        CGContextSetTextPosition(ctx, 10.0, baselineY);
                        CTLineDraw(line, ctx);
                        CFRelease(line);
                    }
                    CFRelease(astr);
                }
                CFRelease(attrs);
            }
        }
        if (white) CGColorRelease(white);
        if (font) CFRelease(font);
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    for (size_t off = 0; off < totalBytes; off += 4) {
        uint8_t a = pixels[off + 3];
        if (a > 0 && a < 255) {
            pixels[off + 0] = (uint8_t)MIN(255u, ((uint32_t)pixels[off + 0] * 255u + (a >> 1)) / a);
            pixels[off + 1] = (uint8_t)MIN(255u, ((uint32_t)pixels[off + 1] * 255u + (a >> 1)) / a);
            pixels[off + 2] = (uint8_t)MIN(255u, ((uint32_t)pixels[off + 2] * 255u + (a >> 1)) / a);
        }
    }
    uintptr_t handle = 0;
    if (dc_vk_sprite_upload(_renderer, w, h, pixels, totalBytes, &handle) == DC_OK && handle) {
        _textTextures[key] = @((unsigned long long)handle);
    }
    free(pixels);
    return handle;
}

- (void)clearTextTextures {
    if (_renderer) {
        for (NSNumber *num in _textTextures.allValues) {
            uintptr_t h = (uintptr_t)num.unsignedLongLongValue;
            if (h) dc_vk_sprite_remove_texture(_renderer, h);
        }
    }
    [_textTextures removeAllObjects];
}

- (NSString *)attachRenderer:(dc_vk_sprite *)renderer {
    if (!renderer) return @"Edit renderer is unavailable";
    if (_renderer == renderer && _textures.count > 0) return nil;
    [self detachRenderer];
    _renderer = renderer;
    NSError *reason = nil;
    _archive = [[DCArchive alloc] initWithURL:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:@"RPP_02.pp"]] error:&reason];
    if (!_archive) return reason.localizedDescription ?: @"Edit archive RPP_02.pp is unavailable";
    _entryIndices = [NSMutableDictionary dictionaryWithCapacity:_archive.entryCount];
    for (uint32_t i = 0; i < _archive.entryCount; ++i) {
        NSString *name = [_archive asciiNameAtIndex:i];
        if (name) _entryIndices[name.lowercaseString] = @(i);
    }
    for (NSString *core in @[@"chara_base.ema", @"motion_base.ema", @"file_base.ema", @"cau_base.ema", @"K_defo.ema"]) {
        if (![self textureNamed:core]) {
            return [NSString stringWithFormat:@"Missing original edit bitmap %@", core];
        }
    }
    return nil;
}

- (void)detachRenderer {
    [self clearTextTextures];
    if (_renderer) {
        for (NSNumber *num in _textures.allValues) {
            uintptr_t h = (uintptr_t)num.unsignedLongLongValue;
            if (h) dc_vk_sprite_remove_texture(_renderer, h);
        }
    }
    [_textures removeAllObjects];
    _archive = nil;
    _entryIndices = nil;
    _renderer = NULL;
}

- (void)pause {
    [_select pause];
    [_toggle pause];
    _draggingPlaylistThumb = NO;
    _draggingFileThumb = NO;
}

- (void)consumeAction {
    _action = 0;
    _pendingAction = 0;
}

- (void)resumeFromTemporaryScreen {
    _pendingAction = 0;
    _action = 0;
    _entered = NO;
    _ready = NO;
    [self updateVolumes];
}

- (void)resumeFromPlaybackAtTick:(uint32_t)tick {
    (void)tick;
    _pendingAction = 0;
    _action = 0;
    _entered = NO;
    _ready = NO;
    _draggingPlaylistThumb = NO;
    _draggingFileThumb = NO;
    [self updateVolumes];
}

- (void)dealloc {
    [self detachRenderer];
    [_select stop];
    [_toggle stop];
}

- (void)refreshEditFiles {
    [self clearTextTextures];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *writableEdit = [[self writableStateDirectory] stringByAppendingPathComponent:@"edit"];
    [fm createDirectoryAtPath:writableEdit withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *realDocs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *gameRoot = [_directory stringByDeletingLastPathComponent];
    NSArray<NSString *> *dirs = @[
        writableEdit ?: @"",
        [_directory stringByAppendingPathComponent:@"edit"] ?: @"",
        [gameRoot stringByAppendingPathComponent:@"edit"] ?: @"",
        realDocs ? [realDocs stringByAppendingPathComponent:@"edit"] : @"",
        realDocs ? [realDocs stringByAppendingPathComponent:@"Data/edit"] : @""
    ];
    NSMutableDictionary<NSString *, NSDictionary *> *byLower = [NSMutableDictionary dictionary];
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = NSTimeZone.localTimeZone;
    dc_edit_state probe;
    for (NSString *dir in dirs) {
        if (!dir.length) continue;
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *item in items) {
            if (![item.lowercaseString hasSuffix:@".edt"]) continue;
            NSString *lower = item.lowercaseString;
            if (byLower[lower]) continue;
            NSString *fullPath = [dir stringByAppendingPathComponent:item];
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            NSNumber *fsize = attrs[NSFileSize];
            NSUInteger minBytes = (NSUInteger)(DC_EDIT_EDT_HEADER_BYTES + DC_EDIT_EDT_STEP_BYTES);
            NSUInteger maxBytes = (NSUInteger)(DC_EDIT_EDT_HEADER_BYTES + DC_EDIT_MAX_STEPS * DC_EDIT_EDT_STEP_BYTES);
            if (!fsize || fsize.unsignedIntegerValue < minBytes || fsize.unsignedIntegerValue > maxBytes) continue;
            NSData *raw = [NSData dataWithContentsOfFile:fullPath];
            if (!raw || dc_edit_deserialize(&probe, raw.bytes, raw.length, item.UTF8String) != DC_OK) continue;
            NSDate *mod = attrs[NSFileModificationDate];
            NSString *dateStr = @"----/--/--       --:--";
            if (mod) {
                NSDateComponents *c = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                                      NSCalendarUnitHour | NSCalendarUnitMinute
                                             fromDate:mod];
                dateStr = [NSString stringWithFormat:@"%04ld/%02ld/%02ld       %02ld:%02ld",
                           (long)c.year, (long)c.month, (long)c.day, (long)c.hour, (long)c.minute];
            }
            byLower[lower] = @{
                @"name": item,
                @"path": fullPath,
                @"date": dateStr
            };
        }
    }
    NSArray<NSString *> *sortedKeys = [byLower.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    [_editFiles removeAllObjects];
    for (NSString *k in sortedKeys) {
        [_editFiles addObject:byLower[k]];
    }
    if (_selectedFileIndex >= _editFiles.count) {
        _selectedFileIndex = 0;
    }
    uint32_t maxScroll = _editFiles.count > 9 ? (uint32_t)(_editFiles.count - 9) : 0;
    if (_fileScroll > maxScroll) _fileScroll = maxScroll;
}

- (BOOL)saveCurrentStateToFilename:(NSString *)fileName {
    if (!fileName.length) return NO;
    size_t needed = dc_edit_serialized_size(&_state);
    if (needed < (size_t)(DC_EDIT_EDT_HEADER_BYTES + DC_EDIT_EDT_STEP_BYTES)) return NO;
    NSMutableData *payload = [NSMutableData dataWithLength:needed];
    size_t written = 0;
    if (dc_edit_serialize(&_state, payload.mutableBytes, payload.length, &written) != DC_OK || written != needed) return NO;
    NSString *editDir = [[self writableStateDirectory] stringByAppendingPathComponent:@"edit"];
    [NSFileManager.defaultManager createDirectoryAtPath:editDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [editDir stringByAppendingPathComponent:fileName];
    if (![payload writeToFile:dst options:NSDataWritingAtomic error:nil]) return NO;
    const char *utf8 = fileName.UTF8String;
    if (utf8) {
        memset(_state.current_filename, 0, sizeof(_state.current_filename));
        strncpy(_state.current_filename, utf8, sizeof(_state.current_filename) - 1u);
    }
    return YES;
}

- (BOOL)saveAutoNamedFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *writableEdit = [[self writableStateDirectory] stringByAppendingPathComponent:@"edit"];
    NSString *directEdit = [_directory stringByAppendingPathComponent:@"edit"];
    NSString *chosen = nil;
    for (uint32_t serial = 0; serial < 1000u; ++serial) {
        char buf[DC_EDIT_FILENAME_CAP];
        if (dc_edit_format_autoname(_state.combo_idx, _state.map_idx, serial, buf) != DC_OK) return NO;
        NSString *cand = [NSString stringWithUTF8String:buf];
        BOOL existsW = [fm fileExistsAtPath:[writableEdit stringByAppendingPathComponent:cand]];
        BOOL existsD = directEdit.length && [fm fileExistsAtPath:[directEdit stringByAppendingPathComponent:cand]];
        chosen = cand;
        if (!existsW && !existsD) break;
    }
    return [self saveCurrentStateToFilename:chosen];
}

- (BOOL)loadSelectedFile {
    if (_selectedFileIndex >= _editFiles.count) return NO;
    NSDictionary *entry = _editFiles[_selectedFileIndex];
    NSString *path = entry[@"path"];
    NSString *name = entry[@"name"];
    NSData *raw = path.length ? [NSData dataWithContentsOfFile:path] : nil;
    if (!raw || dc_edit_deserialize(&_state, raw.bytes, raw.length, name.UTF8String) != DC_OK) return NO;
    _state.tab = (_prevTab == DC_EDIT_TAB_MOTION) ? DC_EDIT_TAB_MOTION : DC_EDIT_TAB_CHARA;
    return YES;
}

- (NSString *)depart:(uint32_t)action tick:(uint32_t)tick {
    _pendingAction = action;
    if (action != 3u) [self playSelect];
    return [_transition requestTransition:action == 3u ? 3u : 2u tick:tick] == DC_OK
        ? nil
        : @"Edit departure transition failed";
}

- (void)appendTexture:(uintptr_t)tex
                    x:(float)x
                    y:(float)y
                    w:(float)w
                    h:(float)h
                   ox:(float)origX
                   oy:(float)origY
                scale:(float)scale
              offsetX:(float)offX
              offsetY:(float)offY
                items:(dc_vk_sprite_item *)items
                count:(size_t *)count
             capacity:(size_t)capacity {
    if (!tex || *count >= capacity) return;
    dc_sprite_pose pose = {
        .width = w * scale,
        .height = h * scale,
        .x = offX + x * scale,
        .y = offY + y * scale,
        .z = 0.5f,
        .origin_x = origX,
        .origin_y = origY,
        .scale_x = 1.f,
        .scale_y = 1.f,
        .alpha = 1.f,
        .red = 1.f,
        .green = 1.f,
        .blue = 1.f,
        .u1 = 1.f,
        .v1 = 1.f
    };
    items[(*count)++] = (dc_vk_sprite_item){ .pose = pose, .texture = tex, .blend_mode = 3 };
}

- (void)appendNamed:(NSString *)name
                  x:(float)x
                  y:(float)y
                  w:(float)w
                  h:(float)h
              scale:(float)scale
            offsetX:(float)offX
            offsetY:(float)offY
              items:(dc_vk_sprite_item *)items
              count:(size_t *)count
           capacity:(size_t)capacity {
    uintptr_t tex = [self textureNamed:name];
    [self appendTexture:tex x:x y:y w:w h:h ox:0.f oy:0.f scale:scale offsetX:offX offsetY:offY
                  items:items count:count capacity:capacity];
}

- (NSString *)badgeSpriteForKind:(int8_t)kind value:(int32_t)val {
    if (val < 0) return nil;
    switch (kind) {
        case DC_EDIT_PARAM_SPEED:
            return (val >= 0 && val < 3) ? [NSString stringWithFormat:@"ed_%s.ema", kSpeedNames[val]] : nil;
        case DC_EDIT_PARAM_LOOP: {
            int clamped = val < 0 ? 0 : (val > 99 ? 99 : (int)val);
            return [NSString stringWithFormat:@"ed_%02d.ema", clamped];
        }
        case DC_EDIT_PARAM_HEROINE:
            return (val >= 0 && val < 3) ? [NSString stringWithFormat:@"ed_%s.ema", kHeroineNames[val]] : nil;
        case DC_EDIT_PARAM_HOLE:
            return (val >= 0 && val < 2) ? [NSString stringWithFormat:@"ed_%s.ema", kHoleNames[val]] : nil;
        case DC_EDIT_PARAM_STRIP:
            return (val >= 0 && val < 8) ? [NSString stringWithFormat:@"ed_%s.ema", kStripNames[val]] : nil;
        default:
            return nil;
    }
}

- (NSString *)drawAtTick:(uint32_t)tick
                 pcInput:(dc_pc_frame)input
                   width:(uint32_t)width
                  height:(uint32_t)height {
    if (!_renderer) return @"Edit renderer detached";
    if (!_entered) {
        if ([_transition requestTransition:4 tick:tick] != DC_OK) return @"Edit entry transition failed";
        _entered = YES;
    }
    uint32_t ready = 0;
    if ([_transition queryTransitionReady:&ready] != DC_OK) return @"Edit transition query failed";
    if (ready) {
        if (_pendingAction == 3u) {
            [_select pause];
            [_toggle pause];
            _action = 3u;
        } else if (_pendingAction && !_select.isPlaying) {
            _action = _pendingAction;
        } else if (!_pendingAction) {
            _ready = YES;
        }
    }

    float scale = fminf((float)width / 1024.f, (float)height / 768.f);
    float ox = ((float)width - 1024.f * scale) * 0.5f;
    float oy = ((float)height - 768.f * scale) * 0.5f;
    float x = scale > 0.f ? (input.x * (float)width - ox) / scale : input.x * 1024.f;
    float y = scale > 0.f ? (input.y * (float)height - oy) / scale : input.y * 768.f;

    dc_edit_chara_ui charaUI = {0};
    dc_edit_motion_ui motionUI = {0};
    dc_edit_build_chara_ui(&_state, &charaUI);
    dc_edit_build_motion_ui(&_state, &motionUI);

    if (!(input.mouse[0] & 1)) {
        _draggingPlaylistThumb = NO;
        _draggingFileThumb = NO;
    }

    BOOL cautionActive = (_state.caution_pending != DC_EDIT_CAUTION_NONE) || (_uiCautionKind != 0u);
    int hoverCaution = -1;
    int hoverBottom = -1;
    int hoverSys = -1;
    int hoverCombo = -1;
    int hoverMap = -1;
    int hoverCharaH = -1, hoverCharaKind = -1, hoverCharaIdx = -1;
    int hoverRow = -1;
    int hoverCand = -1;
    int hoverScrollArrow = -1;
    int hoverSpeed = -1;
    int hoverKey = -1;
    int hoverHeroine = -1;
    int hoverHole = -1;
    int hoverStrip = -1;
    int hoverFileRow = -1;
    int hoverFileArrow = -1;

    if (_ready && !_pendingAction) {
        if (input.keys[1] == 3) {
            NSString *failure = [self depart:3u tick:tick];
            if (failure) return failure;
        } else if (cautionActive) {
            if (editHit(x, y, 560.f, 400.f, 88.f, 48.f)) hoverCaution = 0;
            else if (editHit(x, y, 712.f, 400.f, 88.f, 48.f)) hoverCaution = 1;
            BOOL accept = (hoverCaution == 0 && input.mouse[0] == 3) || input.keys[0x1c] == 3;
            BOOL cancel = (hoverCaution == 1 && input.mouse[0] == 3) || input.mouse[1] == 3;
            if (accept) {
                if (_state.caution_pending != DC_EDIT_CAUTION_NONE) {
                    dc_edit_resolve_caution(&_state, 1);
                    [self playToggle];
                } else if (_uiCautionKind == 1u) {
                    _uiCautionKind = 0u;
                    _prevTab = _state.tab;
                    _state.tab = DC_EDIT_TAB_LOAD;
                    [self refreshEditFiles];
                    [self playSelect];
                } else if (_uiCautionKind == 2u) {
                    _uiCautionKind = 0u;
                    NSString *failure = [self depart:2u tick:tick];
                    if (failure) return failure;
                }
            } else if (cancel) {
                if (_state.caution_pending != DC_EDIT_CAUTION_NONE) {
                    dc_edit_resolve_caution(&_state, 0);
                }
                _uiCautionKind = 0u;
                [self playSelect];
            }
        } else {
            /* Bottom system buttons: GameEnd (48,704) and Title (128,704) */
            if (editHit(x, y, 48.f, 704.f, 56.f, 56.f)) hoverSys = 0;
            else if (editHit(x, y, 128.f, 704.f, 56.f, 56.f)) hoverSys = 1;
            if (hoverSys >= 0 && input.mouse[0] == 3) {
                if (_state.step_count > 1) {
                    _uiCautionKind = 2u;
                    [self playSelect];
                } else {
                    NSString *failure = [self depart:2u tick:tick];
                    if (failure) return failure;
                }
            } else if (_state.tab == DC_EDIT_TAB_LOAD) {
                /* File Browser Tab */
                BOOL hasFiles = (_editFiles.count > 0);
                if (hasFiles && editHit(x, y, 544.f, 632.f, 184.f, 48.f)) hoverBottom = 2;
                else if (editHit(x, y, 784.f, 632.f, 184.f, 48.f)) hoverBottom = 3;

                if (input.mouse[1] == 3 || (hoverBottom == 3 && input.mouse[0] == 3)) {
                    _state.tab = (_prevTab == DC_EDIT_TAB_MOTION) ? DC_EDIT_TAB_MOTION : DC_EDIT_TAB_CHARA;
                    [self playSelect];
                } else if ((hoverBottom == 2 && input.mouse[0] == 3) || (hasFiles && input.keys[0x1c] == 3)) {
                    if ([self loadSelectedFile]) [self playToggle];
                } else if (_draggingFileThumb && _editFiles.count > 9) {
                    uint32_t maxS = (uint32_t)(_editFiles.count - 9);
                    float ratio = fmaxf(0.f, fminf(1.f, (y - 120.f) / 456.f));
                    _fileScroll = (uint32_t)lrintf(ratio * (float)maxS);
                } else {
                    if (_editFiles.count > 9) {
                        uint32_t maxS = (uint32_t)(_editFiles.count - 9);
                        if (input.wheel > 0 && _fileScroll > 0) { --_fileScroll; [self playToggle]; }
                        else if (input.wheel < 0 && _fileScroll < maxS) { ++_fileScroll; [self playToggle]; }
                        if (editHit(x, y, 944.f, 72.f, 32.f, 32.f)) {
                            hoverFileArrow = 0;
                            if (input.mouse[0] == 3 && _fileScroll > 0) { --_fileScroll; [self playToggle]; }
                        } else if (editHit(x, y, 944.f, 592.f, 32.f, 32.f)) {
                            hoverFileArrow = 1;
                            if (input.mouse[0] == 3 && _fileScroll < maxS) { ++_fileScroll; [self playToggle]; }
                        } else if (editHit(x, y, 944.f, 104.f, 32.f, 488.f) && input.mouse[0] == 3) {
                            _draggingFileThumb = YES;
                            float ratio = fmaxf(0.f, fminf(1.f, (y - 120.f) / 456.f));
                            _fileScroll = (uint32_t)lrintf(ratio * (float)maxS);
                        }
                    }
                    for (uint32_t r = 0; r < 9u; ++r) {
                        uint32_t idx = _fileScroll + r;
                        if (idx >= _editFiles.count) break;
                        if (editHit(x, y, 64.f, 104.f + (float)r * 56.f, 856.f, 40.f)) {
                            hoverFileRow = (int)r;
                            if (input.mouse[0] == 3) {
                                if (_selectedFileIndex == idx) {
                                    if ([self loadSelectedFile]) [self playToggle];
                                } else {
                                    _selectedFileIndex = idx;
                                    [self playToggle];
                                }
                            }
                            break;
                        }
                    }
                }
            } else {
                /* Shared Bottom 4 Buttons on Chara & Motion Tabs */
                BOOL canSaveAs = (_state.current_filename[0] != '\0' && motionUI.can_play_or_save != 0);
                BOOL canSaveOrPlay = (motionUI.can_play_or_save != 0);
                if (canSaveAs && editHit(x, y, 64.f, 632.f, 184.f, 48.f)) hoverBottom = 0;
                else if (canSaveOrPlay && editHit(x, y, 304.f, 632.f, 184.f, 48.f)) hoverBottom = 1;
                else if (editHit(x, y, 544.f, 632.f, 184.f, 48.f)) hoverBottom = 2;
                else if (canSaveOrPlay && editHit(x, y, 784.f, 632.f, 184.f, 48.f)) hoverBottom = 3;

                if (hoverBottom >= 0 && input.mouse[0] == 3) {
                    if (hoverBottom == 0) {
                        NSString *cur = [NSString stringWithUTF8String:_state.current_filename];
                        if ([self saveCurrentStateToFilename:cur]) [self playToggle];
                    } else if (hoverBottom == 1) {
                        if ([self saveAutoNamedFile]) [self playToggle];
                    } else if (hoverBottom == 2) {
                        if (_state.step_count > 1) {
                            _uiCautionKind = 1u;
                            [self playSelect];
                        } else {
                            _prevTab = _state.tab;
                            _state.tab = DC_EDIT_TAB_LOAD;
                            [self refreshEditFiles];
                            [self playSelect];
                        }
                    } else if (hoverBottom == 3) {
                        NSString *failure = [self depart:1u tick:tick];
                        if (failure) return failure;
                    }
                } else if (_state.tab == DC_EDIT_TAB_CHARA) {
                    /* Switch to Motion Tab */
                    if (editHit(x, y, 256.f, 8.f, 232.f, 48.f) && input.mouse[0] == 3) {
                        _state.tab = DC_EDIT_TAB_MOTION;
                        [self playSelect];
                    } else {
                        for (int i = 0; i < 10; ++i) {
                            if (editHit(x, y, 256.f + (float)i * 64.f, 72.f, 64.f, 40.f)) {
                                hoverCombo = i;
                                if (input.mouse[0] == 3 && i != (int)_state.combo_idx) {
                                    dc_edit_set_combo(&_state, i);
                                    [self playToggle];
                                }
                                break;
                            }
                        }
                        if (hoverCombo < 0) {
                            for (int m = 0; m < 8; ++m) {
                                if ((charaUI.map_enabled_mask & (1u << m)) == 0) continue;
                                if (editHit(x, y, 256.f + (float)m * 64.f, 136.f, 64.f, 40.f)) {
                                    hoverMap = m;
                                    if (input.mouse[0] == 3 && m != (int)_state.map_idx) {
                                        dc_edit_set_map(&_state, m);
                                        [self playToggle];
                                    }
                                    break;
                                }
                            }
                        }
                        if (hoverCombo < 0 && hoverMap < 0) {
                            static const float kColBtnX[3] = { 784.f, 480.f, 176.f };
                            for (uint8_t h = 0; h < 3u; ++h) {
                                if ((_state.active_mask & (1u << h)) == 0) continue;
                                float bx = kColBtnX[h];
                                dc_edit_state tmp = _state;
                                tmp.chara_heroine = h;
                                dc_edit_chara_ui hui = {0};
                                dc_edit_build_chara_ui(&tmp, &hui);
                                for (int p = 0; p < 3; ++p) {
                                    if ((hui.pers_enabled_mask & (1u << p)) == 0) continue;
                                    if (editHit(x, y, bx + (float)p * 48.f, 256.f, 48.f, 32.f)) {
                                        hoverCharaH = h; hoverCharaKind = 0; hoverCharaIdx = p;
                                        if (input.mouse[0] == 3 && dc_edit_set_personality(&_state, h, p) == DC_OK) {
                                            [self playToggle];
                                        }
                                    }
                                }
                                for (int g = 0; g < 6; ++g) {
                                    if ((hui.preg_enabled_mask & (1u << g)) == 0) continue;
                                    if (editHit(x, y, bx + (float)(g % 3) * 48.f, 312.f + (float)(g / 3) * 32.f, 48.f, 32.f)) {
                                        hoverCharaH = h; hoverCharaKind = 1; hoverCharaIdx = g;
                                        if (input.mouse[0] == 3 && dc_edit_set_pregnancy(&_state, h, g) == DC_OK) {
                                            [self playToggle];
                                        }
                                    }
                                }
                                for (int v = 0; v < 2; ++v) {
                                    if ((hui.virgin_enabled_mask & (1u << v)) == 0) continue;
                                    if (editHit(x, y, bx + (float)v * 48.f, 400.f, 48.f, 32.f)) {
                                        hoverCharaH = h; hoverCharaKind = 2; hoverCharaIdx = v;
                                        if (input.mouse[0] == 3 && dc_edit_set_virgin(&_state, h, (uint8_t)v) == DC_OK) {
                                            [self playToggle];
                                        }
                                    }
                                }
                                if (hui.pubic_enabled) {
                                    for (int ph = 0; ph < 2; ++ph) {
                                        if (editHit(x, y, bx + (float)ph * 48.f, 448.f, 48.f, 32.f)) {
                                            hoverCharaH = h; hoverCharaKind = 3; hoverCharaIdx = ph;
                                            if (input.mouse[0] == 3 && dc_edit_set_pubic_hair(&_state, h, (uint8_t)ph) == DC_OK) {
                                                [self playToggle];
                                            }
                                        }
                                    }
                                }
                                for (int b = 0; b < 9; ++b) {
                                    if ((hui.badges_enabled_mask & (1u << b)) == 0) continue;
                                    if (editHit(x, y, bx + (float)(b % 3) * 48.f, 504.f + (float)(b / 3) * 32.f, 48.f, 32.f)) {
                                        hoverCharaH = h; hoverCharaKind = 4; hoverCharaIdx = b;
                                        if (input.mouse[0] == 3 && dc_edit_toggle_badge(&_state, h, (uint8_t)b) == DC_OK) {
                                            [self playToggle];
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if (_state.tab == DC_EDIT_TAB_MOTION) {
                    /* Motion Tab */
                    if (editHit(x, y, 16.f, 8.f, 240.f, 48.f) && input.mouse[0] == 3) {
                        _state.tab = DC_EDIT_TAB_CHARA;
                        [self playSelect];
                    } else if (input.mouse[1] == 3 || input.keys[0x0e] == 3 || input.keys[0xd3] == 3) {
                        if (dc_edit_pop_last_step(&_state) == DC_OK) [self playSelect];
                    } else if (_draggingPlaylistThumb && _state.step_count > 7) {
                        int32_t maxS = _state.step_count - 7;
                        float ratio = fmaxf(0.f, fminf(1.f, (y - 160.f) / 416.f));
                        _state.list_scroll = (int32_t)lrintf(ratio * (float)maxS);
                    } else {
                        if (_state.step_count > 7 && !(motionUI.cand_page_count > 1u && x >= 500.f && y < 360.f)) {
                            if (input.wheel > 0) { dc_edit_scroll_list(&_state, -1); }
                            else if (input.wheel < 0) { dc_edit_scroll_list(&_state, 1); }
                        }
                        if (_state.step_count > 7) {
                            if (editHit(x, y, 448.f, 112.f, 32.f, 32.f)) {
                                hoverScrollArrow = 0;
                                if (input.mouse[0] == 3) { dc_edit_scroll_list(&_state, -1); [self playToggle]; }
                            } else if (editHit(x, y, 448.f, 592.f, 32.f, 32.f)) {
                                hoverScrollArrow = 1;
                                if (input.mouse[0] == 3) { dc_edit_scroll_list(&_state, 1); [self playToggle]; }
                            } else if (editHit(x, y, 448.f, 144.f, 32.f, 448.f) && input.mouse[0] == 3) {
                                _draggingPlaylistThumb = YES;
                                int32_t maxS = _state.step_count - 7;
                                float ratio = fmaxf(0.f, fminf(1.f, (y - 160.f) / 416.f));
                                _state.list_scroll = (int32_t)lrintf(ratio * (float)maxS);
                            }
                        }
                        if (motionUI.cand_page_count > 1u) {
                            BOOL prevCand = (input.keys[0xc9] == 3) || (x >= 500.f && y < 360.f && input.wheel > 0);
                            BOOL nextCand = (input.keys[0xd1] == 3) || (x >= 500.f && y < 360.f && input.wheel < 0);
                            if (prevCand && _state.cand_page > 0) {
                                dc_edit_set_cand_page(&_state, _state.cand_page - 1u);
                            } else if (nextCand && _state.cand_page + 1u < motionUI.cand_page_count) {
                                dc_edit_set_cand_page(&_state, _state.cand_page + 1u);
                            }
                        }
                        for (int32_t r = 0; r < 7; ++r) {
                            int32_t idx = _state.list_scroll + r;
                            if (idx >= _state.step_count) break;
                            if (editHit(x, y, 40.f, 120.f + (float)r * 72.f, 392.f, 56.f)) {
                                hoverRow = (int)r;
                                if (input.mouse[0] == 3 && dc_edit_select_step(&_state, idx) == DC_OK) {
                                    [self playToggle];
                                }
                                break;
                            }
                        }
                        for (uint8_t slot = 0; slot < 12u; ++slot) {
                            uint8_t cIdx = (uint8_t)(motionUI.cand_page * 12u + slot);
                            if (cIdx >= motionUI.cand_count) break;
                            float cx = (slot >= 6u) ? 760.f : 520.f;
                            float cy = 104.f + (float)(slot % 6u) * 40.f;
                            if (editHit(x, y, cx, cy, 216.f, 40.f)) {
                                hoverCand = (int)slot;
                                if (input.mouse[0] == 3 &&
                                    dc_edit_append_candidate(&_state, motionUI.cand_cat_idx[cIdx]) == DC_OK) {
                                    [self playToggle];
                                }
                                break;
                            }
                        }
                        /* Parameter buttons */
                        for (int s = 0; s < 3; ++s) {
                            if ((motionUI.speed_enabled_mask & (1u << s)) == 0) continue;
                            if (editHit(x, y, kSpeedBtnX[s], 392.f, 64.f, 32.f)) {
                                hoverSpeed = s;
                                if (input.mouse[0] == 3 && dc_edit_set_speed_param(&_state, s) == DC_OK) {
                                    [self playToggle];
                                }
                            }
                        }
                        if (motionUI.keypad_enabled) {
                            for (int k = 0; k < 11; ++k) {
                                if (editHit(x, y, kKeypadX[k], kKeypadY[k], 64.f, 32.f)) {
                                    hoverKey = k;
                                    if (input.mouse[0] == 3 && dc_edit_keypad_press(&_state, k) == DC_OK) {
                                        [self playToggle];
                                    }
                                }
                            }
                        }
                        for (int h = 0; h < 3; ++h) {
                            if ((motionUI.heroine_enabled_mask & (1u << h)) == 0) continue;
                            if (editHit(x, y, kHeroineBtnX[h], 392.f, 64.f, 32.f)) {
                                hoverHeroine = h;
                                if (input.mouse[0] == 3 && dc_edit_set_heroine_param(&_state, (uint8_t)h) == DC_OK) {
                                    [self playToggle];
                                }
                            }
                        }
                        for (int hl = 0; hl < 2; ++hl) {
                            if ((motionUI.hole_enabled_mask & (1u << hl)) == 0) continue;
                            if (editHit(x, y, kHoleBtnX[hl], 448.f, 64.f, 32.f)) {
                                hoverHole = hl;
                                if (input.mouse[0] == 3 && dc_edit_set_hole_param(&_state, (uint8_t)hl) == DC_OK) {
                                    [self playToggle];
                                }
                            }
                        }
                        for (int st = 0; st < 8; ++st) {
                            if ((motionUI.strip_enabled_mask & (1u << st)) == 0) continue;
                            if (editHit(x, y, kStripBtnX[st], kStripBtnY[st], 64.f, 32.f)) {
                                hoverStrip = st;
                                if (input.mouse[0] == 3 && dc_edit_set_strip_param(&_state, (uint8_t)st) == DC_OK) {
                                    [self playToggle];
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /* Rebuild UI snapshots after input mutations so this frame's sprites match exact state */
    dc_edit_build_chara_ui(&_state, &charaUI);
    dc_edit_build_motion_ui(&_state, &motionUI);

    enum { kMaxEditSprites = 768 };
    dc_vk_sprite_item items[kMaxEditSprites] = {0};
    size_t count = 0;
#define EDIT_ADD(nm, px, py, pw, ph) \
    [self appendNamed:(nm) x:(px) y:(py) w:(pw) h:(ph) scale:scale offsetX:ox offsetY:oy items:items count:&count capacity:kMaxEditSprites]

    if (_state.tab == DC_EDIT_TAB_LOAD) {
        EDIT_ADD(@"file_base.ema", 0.f, 0.f, 1024.f, 768.f);
        for (uint32_t r = 0; r < 9u; ++r) {
            uint32_t idx = _fileScroll + r;
            if (idx >= _editFiles.count) break;
            float ry = 104.f + (float)r * 56.f;
            if (idx == _selectedFileIndex || hoverFileRow == (int)r) {
                EDIT_ADD(@"file_sel.ema", 64.f, ry, 856.f, 40.f);
            }
            NSDictionary *entry = _editFiles[idx];
            NSString *fname = entry[@"name"];
            NSString *fdate = entry[@"date"];
            uintptr_t nameTex = [self textTextureForKey:[NSString stringWithFormat:@"n:%@", fname.lowercaseString]
                                                   text:fname width:535u height:40u];
            uintptr_t dateTex = [self textTextureForKey:[NSString stringWithFormat:@"d:%@:%@", fname.lowercaseString, fdate]
                                                   text:fdate width:321u height:40u];
            [self appendTexture:nameTex x:64.f y:ry w:535.f h:40.f ox:0.f oy:0.f
                          scale:scale offsetX:ox offsetY:oy items:items count:&count capacity:kMaxEditSprites];
            [self appendTexture:dateTex x:599.f y:ry w:321.f h:40.f ox:0.f oy:0.f
                          scale:scale offsetX:ox offsetY:oy items:items count:&count capacity:kMaxEditSprites];
        }
        if (_editFiles.count > 9u) {
            if (hoverFileArrow == 0) EDIT_ADD(@"slider_ue.ema", 944.f, 72.f, 32.f, 32.f);
            if (hoverFileArrow == 1) EDIT_ADD(@"slider_sita.ema", 944.f, 592.f, 32.f, 32.f);
            uint32_t maxS = (uint32_t)(_editFiles.count - 9u);
            float ty = 104.f + (456.f * (float)_fileScroll) / (float)maxS;
            EDIT_ADD(@"slider.ema", 952.f, ty, 16.f, 32.f);
        }
        EDIT_ADD(@"save as_mo.ema", 64.f, 632.f, 184.f, 48.f);
        EDIT_ADD(@"save_mo.ema", 304.f, 632.f, 184.f, 48.f);
        if (_editFiles.count == 0) EDIT_ADD(@"load_mo.ema", 544.f, 632.f, 184.f, 48.f);
        else if (hoverBottom == 2) EDIT_ADD(@"load_s.ema", 544.f, 632.f, 184.f, 48.f);
        if (hoverBottom == 3) EDIT_ADD(@"cancel_s.ema", 784.f, 632.f, 184.f, 48.f);
    } else if (_state.tab == DC_EDIT_TAB_CHARA) {
        EDIT_ADD(@"chara_base.ema", 0.f, 0.f, 1024.f, 768.f);
        for (int i = 0; i < 10; ++i) {
            if (i == (int)_state.combo_idx || i == hoverCombo) {
                EDIT_ADD(([NSString stringWithFormat:@"%s_s.ema", kComboNames[i]]),
                         256.f + (float)i * 64.f, 72.f, 64.f, 40.f);
            }
        }
        for (int m = 0; m < 8; ++m) {
            float mx = 256.f + (float)m * 64.f;
            if ((charaUI.map_enabled_mask & (1u << m)) == 0) {
                EDIT_ADD(([NSString stringWithFormat:@"%s_mo.ema", kMapNames[m]]), mx, 136.f, 64.f, 40.f);
            } else if (m == (int)_state.map_idx || m == hoverMap) {
                EDIT_ADD(([NSString stringWithFormat:@"%s_s.ema", kMapNames[m]]), mx, 136.f, 64.f, 40.f);
            }
        }
        static const float kColPanelX[3] = { 656.f, 352.f, 48.f };
        static const float kColBtnX[3] = { 784.f, 480.f, 176.f };
        for (uint8_t h = 0; h < 3u; ++h) {
            if ((_state.active_mask & (1u << h)) == 0) {
                EDIT_ADD(([NSString stringWithFormat:@"sta_%s_mo.ema", kHeroineNames[h]]),
                         kColPanelX[h], 192.f, 296.f, 424.f);
                continue;
            }
            float bx = kColBtnX[h];
            dc_edit_state tmp = _state;
            tmp.chara_heroine = h;
            dc_edit_chara_ui hui = {0};
            dc_edit_build_chara_ui(&tmp, &hui);
            for (int p = 0; p < 3; ++p) {
                float px = bx + (float)p * 48.f;
                if ((hui.pers_enabled_mask & (1u << p)) == 0) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_mo.ema", kPersonalityNames[p]]), px, 256.f, 48.f, 32.f);
                } else if (_state.personality[h] == p ||
                           (hoverCharaH == (int)h && hoverCharaKind == 0 && hoverCharaIdx == p)) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_s.ema", kPersonalityNames[p]]), px, 256.f, 48.f, 32.f);
                }
            }
            for (int g = 0; g < 6; ++g) {
                float gx = bx + (float)(g % 3) * 48.f;
                float gy = 312.f + (float)(g / 3) * 32.f;
                if ((hui.preg_enabled_mask & (1u << g)) == 0) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_mo.ema", kPregnancyNames[g]]), gx, gy, 48.f, 32.f);
                } else if (_state.pregnancy[h] == g ||
                           (hoverCharaH == (int)h && hoverCharaKind == 1 && hoverCharaIdx == g)) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_s.ema", kPregnancyNames[g]]), gx, gy, 48.f, 32.f);
                }
            }
            static const char *const kNasiAri[2] = { "nasi", "ari" };
            for (int v = 0; v < 2; ++v) {
                float vx = bx + (float)v * 48.f;
                if ((hui.virgin_enabled_mask & (1u << v)) == 0) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_mo.ema", kNasiAri[v]]), vx, 400.f, 48.f, 32.f);
                } else if (_state.non_virgin[h] == (uint8_t)v ||
                           (hoverCharaH == (int)h && hoverCharaKind == 2 && hoverCharaIdx == v)) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_s.ema", kNasiAri[v]]), vx, 400.f, 48.f, 32.f);
                }
            }
            for (int ph = 0; ph < 2; ++ph) {
                float phx = bx + (float)ph * 48.f;
                if (!hui.pubic_enabled) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_mo.ema", kNasiAri[ph]]), phx, 448.f, 48.f, 32.f);
                } else if (_state.pubic_hair[h] == (uint8_t)ph ||
                           (hoverCharaH == (int)h && hoverCharaKind == 3 && hoverCharaIdx == ph)) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_s.ema", kNasiAri[ph]]), phx, 448.f, 48.f, 32.f);
                }
            }
            for (int b = 0; b < 9; ++b) {
                float bgx = bx + (float)(b % 3) * 48.f;
                float bgy = 504.f + (float)(b / 3) * 32.f;
                if (_state.badges[h][b] ||
                    (hoverCharaH == (int)h && hoverCharaKind == 4 && hoverCharaIdx == b)) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_s.ema", kBadgeNames[b]]), bgx, bgy, 48.f, 32.f);
                } else if ((hui.badges_enabled_mask & (1u << b)) == 0) {
                    EDIT_ADD(([NSString stringWithFormat:@"%s_mo.ema", kBadgeNames[b]]), bgx, bgy, 48.f, 32.f);
                }
            }
        }
    } else {
        /* Motion Tab */
        EDIT_ADD(@"motion_base.ema", 0.f, 0.f, 1024.f, 768.f);
        uint32_t totalSteps = MIN(999u, (uint32_t)MAX(0, _state.step_count));
        EDIT_ADD(([NSString stringWithFormat:@"Save_file_%02u.ema", (totalSteps / 100u) % 10u]), 302.f, 84.f, 16.f, 24.f);
        EDIT_ADD(([NSString stringWithFormat:@"Save_file_%02u.ema", (totalSteps / 10u) % 10u]), 318.f, 84.f, 16.f, 24.f);
        EDIT_ADD(([NSString stringWithFormat:@"Save_file_%02u.ema", totalSteps % 10u]), 334.f, 84.f, 16.f, 24.f);

        for (int32_t r = 0; r < 7; ++r) {
            int32_t idx = _state.list_scroll + r;
            if (idx >= _state.step_count) break;
            if (idx == _state.selected_step) {
                EDIT_ADD(@"edit_select.ema", 40.f, 120.f + (float)r * 72.f, 392.f, 56.f);
            }
            const dc_edit_step *st = &_state.steps[idx];
            char spName[DC_EDIT_NAME_CAP];
            uint8_t selFlag = (idx == _state.selected_step || hoverRow == (int)r) ? 1u : 0u;
            if (dc_edit_motion_sprite_name(st->motion_id, selFlag, spName) == DC_OK) {
                EDIT_ADD([NSString stringWithUTF8String:spName], 48.f, 128.f + (float)r * 72.f, 216.f, 40.f);
            }
            int8_t k1 = DC_EDIT_PARAM_NONE, k2 = DC_EDIT_PARAM_NONE;
            if (dc_edit_motion_param_kinds(st->motion_id, &k1, &k2) == DC_OK) {
                NSString *b1 = [self badgeSpriteForKind:k1 value:st->param1];
                NSString *b2 = [self badgeSpriteForKind:k2 value:st->param2];
                if (b1) EDIT_ADD(b1, 280.f, 136.f + (float)r * 72.f, 64.f, 32.f);
                if (b2) EDIT_ADD(b2, 360.f, 136.f + (float)r * 72.f, 64.f, 32.f);
            }
        }

        if (_state.step_count > 7) {
            if (hoverScrollArrow == 0) EDIT_ADD(@"slider_ue.ema", 448.f, 112.f, 32.f, 32.f);
            if (hoverScrollArrow == 1) EDIT_ADD(@"slider_sita.ema", 448.f, 592.f, 32.f, 32.f);
            int32_t maxS = _state.step_count - 7;
            float ty = 144.f + (416.f * (float)_state.list_scroll) / (float)maxS;
            EDIT_ADD(@"slider.ema", 456.f, ty, 16.f, 32.f);
        }

        for (uint8_t slot = 0; slot < 12u; ++slot) {
            uint8_t cIdx = (uint8_t)(motionUI.cand_page * 12u + slot);
            if (cIdx >= motionUI.cand_count) break;
            float cx = (slot >= 6u) ? 760.f : 520.f;
            float cy = 104.f + (float)(slot % 6u) * 40.f;
            char spName[DC_EDIT_NAME_CAP];
            if (dc_edit_motion_sprite_name(motionUI.cand_motion_id[cIdx],
                                           hoverCand == (int)slot ? 1u : 0u,
                                           spName) == DC_OK) {
                EDIT_ADD([NSString stringWithUTF8String:spName], cx, cy, 216.f, 40.f);
            }
        }

        const dc_edit_step *selStep = (_state.selected_step >= 0 && _state.selected_step < _state.step_count)
            ? &_state.steps[_state.selected_step]
            : NULL;
        int8_t sk1 = DC_EDIT_PARAM_NONE, sk2 = DC_EDIT_PARAM_NONE;
        if (selStep) dc_edit_motion_param_kinds(selStep->motion_id, &sk1, &sk2);

        for (int s = 0; s < 3; ++s) {
            if ((motionUI.speed_enabled_mask & (1u << s)) == 0) continue;
            BOOL active = (hoverSpeed == s) || (selStep && sk1 == DC_EDIT_PARAM_SPEED && selStep->param1 == s);
            EDIT_ADD(([NSString stringWithFormat:@"%s_%s.ema", active ? "sh" : "ed", kSpeedNames[s]]),
                     kSpeedBtnX[s], 392.f, 64.f, 32.f);
        }
        if (motionUI.keypad_enabled) {
            for (int k = 0; k < 10; ++k) {
                NSString *nm = (hoverKey == k)
                    ? [NSString stringWithFormat:@"sh_%d.ema", k]
                    : [NSString stringWithFormat:@"ed_%02d.ema", k];
                EDIT_ADD(nm, kKeypadX[k], kKeypadY[k], 64.f, 32.f);
            }
            EDIT_ADD(hoverKey == 10 ? @"sh_c.ema" : @"ed_c.ema", kKeypadX[10], kKeypadY[10], 64.f, 32.f);
        }
        for (int h = 0; h < 3; ++h) {
            if ((motionUI.heroine_enabled_mask & (1u << h)) == 0) continue;
            BOOL active = (hoverHeroine == h) || (selStep && sk2 == DC_EDIT_PARAM_HEROINE && selStep->param2 == h);
            EDIT_ADD(([NSString stringWithFormat:@"%s_%s.ema", active ? "sh" : "ed", kHeroineNames[h]]),
                     kHeroineBtnX[h], 392.f, 64.f, 32.f);
        }
        for (int hl = 0; hl < 2; ++hl) {
            if ((motionUI.hole_enabled_mask & (1u << hl)) == 0) continue;
            int32_t curHole = -1;
            if (selStep) {
                if (sk1 == DC_EDIT_PARAM_HOLE) curHole = selStep->param1;
                else if (sk2 == DC_EDIT_PARAM_HOLE) curHole = selStep->param2;
            }
            BOOL active = (hoverHole == hl) || (curHole == hl);
            EDIT_ADD(([NSString stringWithFormat:@"%s_%s.ema", active ? "sh" : "ed", kHoleNames[hl]]),
                     kHoleBtnX[hl], 448.f, 64.f, 32.f);
        }
        for (int st = 0; st < 8; ++st) {
            if ((motionUI.strip_enabled_mask & (1u << st)) == 0) continue;
            BOOL active = (hoverStrip == st) || (selStep && sk1 == DC_EDIT_PARAM_STRIP && selStep->param1 == st);
            EDIT_ADD(([NSString stringWithFormat:@"%s_%s.ema", active ? "sh" : "ed", kStripNames[st]]),
                     kStripBtnX[st], kStripBtnY[st], 64.f, 32.f);
        }
    }

    if (_state.tab != DC_EDIT_TAB_LOAD) {
        BOOL canSaveAs = (_state.current_filename[0] != '\0' && motionUI.can_play_or_save != 0);
        BOOL canSaveOrPlay = (motionUI.can_play_or_save != 0);
        if (!canSaveAs) EDIT_ADD(@"save as_mo.ema", 64.f, 632.f, 184.f, 48.f);
        else if (hoverBottom == 0) EDIT_ADD(@"save as_s.ema", 64.f, 632.f, 184.f, 48.f);
        if (!canSaveOrPlay) EDIT_ADD(@"save_mo.ema", 304.f, 632.f, 184.f, 48.f);
        else if (hoverBottom == 1) EDIT_ADD(@"save_s.ema", 304.f, 632.f, 184.f, 48.f);
        if (hoverBottom == 2) EDIT_ADD(@"load_s.ema", 544.f, 632.f, 184.f, 48.f);
        if (!canSaveOrPlay) EDIT_ADD(@"play_mo.ema", 784.f, 632.f, 184.f, 48.f);
        else if (hoverBottom == 3) EDIT_ADD(@"play_s.ema", 784.f, 632.f, 184.f, 48.f);
    }

    if (hoverSys == 0) EDIT_ADD(@"hanyo_gameend.ema", 48.f, 704.f, 56.f, 56.f);
    if (hoverSys == 1) EDIT_ADD(@"hanyo_title.ema", 128.f, 704.f, 56.f, 56.f);

    if ((_state.caution_pending != DC_EDIT_CAUTION_NONE) || (_uiCautionKind != 0u)) {
        EDIT_ADD(@"cau_base.ema", 0.f, 0.f, 1024.f, 768.f);
        if (hoverCaution == 0) EDIT_ADD(@"cau_yes.ema", 560.f, 400.f, 88.f, 48.f);
        if (hoverCaution == 1) EDIT_ADD(@"cau_no.ema", 712.f, 400.f, 88.f, 48.f);
    }

    uintptr_t cursorTex = [self textureNamed:@"K_defo.ema"];
    [self appendTexture:cursorTex x:x y:y w:64.f h:64.f ox:0.1f oy:0.1f
                  scale:scale offsetX:ox offsetY:oy items:items count:&count capacity:kMaxEditSprites];
#undef EDIT_ADD

    if (input.keys[0x2e] == 3) _captureName = @"system-edit-native.png";
    NSMutableData *pixels = _captureName ? [NSMutableData dataWithLength:(size_t)width * height * 4] : nil;
    NSString *failure = [_transition drawSprites:items count:count tick:tick width:width height:height readback:pixels];
    if (failure) return failure;
    if (pixels) {
        NSString *name = _captureName.lastPathComponent;
        _captureName = nil;
        NSString *outDir = [_directory stringByDeletingLastPathComponent];
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGImageRef image = CGImageCreate(width, height, 8, 32, width * 4, color,
                                         kCGBitmapByteOrder32Big | kCGImageAlphaLast, provider,
                                         NULL, false, kCGRenderingIntentDefault);
        NSURL *url = [NSURL fileURLWithPath:[outDir stringByAppendingPathComponent:name]];
        CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
        if (!image || !destination) {
            if (destination) CFRelease(destination);
            if (image) CGImageRelease(image);
            CGDataProviderRelease(provider);
            CGColorSpaceRelease(color);
            return @"Edit capture allocation failed";
        }
        CGImageDestinationAddImage(destination, image, NULL);
        BOOL written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(color);
        if (!written) return @"Edit capture write failed";
        _lastRenderCapture = @{
            @"file": name,
            @"width": @(width),
            @"height": @(height),
            @"draws": @(count),
            @"tab": @(_state.tab),
            @"combo": @(_state.combo_idx),
            @"map": @(_state.map_idx),
            @"steps": @(_state.step_count),
            @"selectedStep": @(_state.selected_step),
            @"action": @(_action)
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:_lastRenderCapture options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[[outDir stringByAppendingPathComponent:name] stringByAppendingString:@".json"] atomically:YES];
    }
    return nil;
}
@end
