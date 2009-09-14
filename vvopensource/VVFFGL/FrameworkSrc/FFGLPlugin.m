//
//  FFGLPlugin.m
//  VVOpenSource
//
//  Created by Tom on 23/07/2009.
//

#import "FFGLPlugin.h"
#import "FFGLPluginInstances.h"
#import "FreeFrame.h"
#import "FFGL.h"

#import <pthread.h> // Remove this if we switch to some other locking mechanism.

struct FFGLPluginData {
    CFBundleRef bundle;
    FF_Main_FuncPtr main;
    BOOL initted;
    FFGLPluginType type;
    FFGLPluginMode mode;
    NSUInteger minFrames;
    NSUInteger maxFrames;
    NSUInteger preferredBufferMode;
    BOOL supportsSetTime;
    NSArray *bufferPixelFormats;
    NSDictionary *parameters;
    NSDictionary *attributes;
    NSString *identifier;
};

NSString * const FFGLPluginBufferPixelFormatARGB8888 = @"FFGLPluginBufferPixelFormatARGB8888";
NSString * const FFGLPluginBufferPixelFormatBGRA8888 = @"FFGLPluginBufferPixelFormatBGRA8888";
NSString * const FFGLPluginBufferPixelFormatRGB888 = @"FFGLPluginBufferPixelFormatRGB888";
NSString * const FFGLPluginBufferPixelFormatBGR888 = @"FFGLPluginBufferPixelFormatBGR888";
NSString * const FFGLPluginBufferPixelFormatRGB565 = @"FFGLPluginBufferPixelFormatRGB565";
NSString * const FFGLPluginBufferPixelFormatBGR565 = @"FFGLPluginBufferPixelFormatBGR565";

NSString * const FFGLPluginAttributeNameKey = @"FFGLPluginAttributeNameKey";
NSString * const FFGLPluginAttributeVersionKey = @"FFGLPluginAttributeVersionKey";
NSString * const FFGLPluginAttributeDescriptionKey = @"FFGLPluginAttributeDescriptionKey";
NSString * const FFGLPluginAttributeAuthorKey = @"FFGLPluginAttributeAuthorKey";
NSString * const FFGLPluginAttributePathKey = @"FFGLPluginAttributePathKey";

NSString * const FFGLParameterAttributeTypeKey = @"FFGLParameterAttributeTypeKey";
NSString * const FFGLParameterAttributeNameKey = @"FFGLParameterAttributeNameKey";
NSString * const FFGLParameterAttributeDefaultValueKey = @"FFGLParameterAttributeDefaultValueKey";
NSString * const FFGLParameterAttributeMinimumValueKey = @"FFGLParameterAttributeMinimumValueKey";
NSString * const FFGLParameterAttributeMaximumValueKey = @"FFGLParameterAttributeMaximumValueKey";
NSString * const FFGLParameterAttributeRequiredKey = @"FFGLParameterAttributeRequiredKey";
NSString * const FFGLParameterAttributeIndexKey = @"FFGLParameterAttributeIndexKey"; // Private

NSString * const FFGLParameterTypeBoolean = @"FFGLParameterTypeBoolean";
NSString * const FFGLParameterTypeEvent = @"FFGLParameterTypeEvent";
//NSString * const FFGLParameterTypePoint = @"FFGLParameterTypePoint";
NSString * const FFGLParameterTypeNumber = @"FFGLParameterTypeNumber";
NSString * const FFGLParameterTypeString = @"FFGLParameterTypeString";
//NSString * const FFGLParameterTypeColor = @"FFGLParameterTypeColor";
NSString * const FFGLParameterTypeImage = @"FFGLParameterTypeImage";

static NSMutableDictionary *_FFGLPluginInstances = nil;
static pthread_mutex_t  _FFGLPluginInstancesLock;
@implementation FFGLPlugin

+ (void)initialise
{
    /*
     We keep track of all instances using a dictionary, returning an existing instance for a path passed in at init if one exists.
     Our dictionary doesn't retain its contents, so FFGLPlugins can still be released. We intercept release messages to remove the
     plugin from the dictionary before dealloc is called.
     */
    if (pthread_mutex_init(&_FFGLPluginInstancesLock, NULL) == 0) {
        _FFGLPluginInstances = (NSMutableDictionary *)CFDictionaryCreateMutable(kCFAllocatorDefault, 10, &kCFTypeDictionaryKeyCallBacks, NULL);
    }
}

- (id)init
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (id)initWithPath:(NSString *)path
{
    if (self = [super init]) {
        FFGLPlugin *p;
        pthread_mutex_lock(&_FFGLPluginInstancesLock);
        p = [_FFGLPluginInstances objectForKey:path];
        if (p != nil) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return [p retain];
        }
        if (path == nil) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }
        _pluginData = malloc(sizeof(struct FFGLPluginData));
        if (_pluginData == NULL) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }
        // Set everything we need in dealloc, in case we bail from init.
        _pluginData->initted = NO;
        _pluginData->bundle = NULL;
        _pluginData->bufferPixelFormats = nil;
        _pluginData->parameters = nil;
        _pluginData->attributes = nil;
        _pluginData->identifier = nil;
        
        // Load the plugin bundle.
        NSURL *url = [NSURL fileURLWithPath:path isDirectory:NO];
        if (url == nil) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }
        _pluginData->bundle = CFBundleCreate(kCFAllocatorDefault, (CFURLRef)url);
        if (_pluginData->bundle == NULL) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }
        
        // Get a pointer to the function.
        _pluginData->main = CFBundleGetFunctionPointerForName(_pluginData->bundle, CFSTR("plugMain"));
        if (_pluginData->main == NULL) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }

        // Get basic plugin info, and check we are a type (source or effect) we know about.
        plugMainUnion result;
        result = _pluginData->main(FF_GETINFO, 0, 0);
        if (result.svalue == NULL) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }
        PluginInfoStruct *info = (PluginInfoStruct *)result.svalue;
        if ((info->PluginType != FF_SOURCE) && (info->PluginType != FF_EFFECT)) {
            // Bail if this is some future other type of plugin.
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }
        
        /*
         Long init
            Current strategy is to do all our parameter/attributes calls to the plugin at init, so we can give that information out without locks
            because we won't be changing anything in memory after init... Can change if it proves problematic, in which case the below will move
            to respective methods.
         */
        
        // Set our identifier and type from the PluginInfoStruct.
        _pluginData->identifier = [[NSString alloc] initWithBytes:info->PluginUniqueID length:4 encoding:NSASCIIStringEncoding];
        _pluginData->type = info->PluginType;
        
        // Get extended info, and fill out our attributes dictionary.
        NSString *name;
        if(info->PluginName)
            name = [[[NSString alloc] initWithBytes:info->PluginName length:16 encoding:NSASCIIStringEncoding] autorelease];
        else
            name = [self identifier];

        result = _pluginData->main(FF_GETEXTENDEDINFO, 0, 0);
        PluginExtendedInfoStruct *extendedInfo = (PluginExtendedInfoStruct *)result.svalue;
        if (extendedInfo != NULL) {
            NSNumber *version = [NSNumber numberWithFloat:extendedInfo->PluginMajorVersion + (extendedInfo->PluginMinorVersion * 0.001)];
            
            NSString *description;
            if (extendedInfo->Description)
                description = [NSString stringWithCString:extendedInfo->Description encoding:NSASCIIStringEncoding];
            else
                description = @"";
            
            NSString *author;
            if (extendedInfo->About)
                author = [NSString stringWithCString:extendedInfo->About encoding:NSASCIIStringEncoding];
            else
                author = @"";
            
            _pluginData->attributes = [[NSDictionary alloc] initWithObjectsAndKeys:name, FFGLPluginAttributeNameKey, version, FFGLPluginAttributeVersionKey,
                                       description, FFGLPluginAttributeDescriptionKey, author, FFGLPluginAttributeAuthorKey,
                                       [[path copy] autorelease], FFGLPluginAttributePathKey, nil];
        } else {
            _pluginData->attributes = [[NSDictionary alloc] initWithObjectsAndKeys:name, FFGLPluginAttributeNameKey, path, FFGLPluginAttributePathKey, nil];
        }
        
        // Determine our mode.
        result = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_PROCESSOPENGL, 0);
        if (result.ivalue == FF_SUPPORTED) {
            _pluginData->mode = FFGLPluginModeGPU;
            // We don't support any pixel formats.
            _pluginData->bufferPixelFormats = [[NSArray alloc] init];
        } else {
            _pluginData->mode = FFGLPluginModeCPU;
            // Fill out our preferred mode
            _pluginData->preferredBufferMode = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_COPYORINPLACE, 0).ivalue;
            /*
             Get information about the pixel formats we support. FF plugins only support native-endian pixel formats. We could
             support both and handle conversion, however that doesn't seem a priority.
             */
            _pluginData->bufferPixelFormats = [[NSMutableArray alloc] initWithCapacity:3];
            result = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_16BITVIDEO, 0);
            if (result.ivalue == FF_SUPPORTED) {
#if __BIG_ENDIAN__
                [(NSMutableArray *)_pluginData->bufferPixelFormats addObject:FFGLPluginBufferPixelFormatRGB565];
#else
                [(NSMutableArray *)_pluginData->bufferPixelFormats addObject:FFGLPluginBufferPixelFormatBGR565];
#endif
            }
            result = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_24BITVIDEO, 0);
            if (result.ivalue == FF_SUPPORTED) {
#if __BIG_ENDIAN__
                [(NSMutableArray *)_pluginData->bufferPixelFormats addObject:FFGLPluginBufferPixelFormatRGB888];
#else
                [(NSMutableArray *)_pluginData->bufferPixelFormats addObject:FFGLPluginBufferPixelFormatBGR888];
#endif
            }
            result = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_32BITVIDEO, 0);
            if (result.ivalue == FF_SUPPORTED) {
#if __BIG_ENDIAN__
                [(NSMutableArray *)_pluginData->bufferPixelFormats addObject:FFGLPluginBufferPixelFormatARGB8888];
#else
                [(NSMutableArray *)_pluginData->bufferPixelFormats addObject:FFGLPluginBufferPixelFormatBGRA8888];
#endif
            }            
        }
        
        // See if we support setTime
        _pluginData->supportsSetTime = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_SETTIME, 0).ivalue;
        
        // Discover our parameters, which include the plugin's parameters plus video inputs.
        _pluginData->parameters = [[NSMutableDictionary alloc] initWithCapacity:4];
        NSUInteger i = 0;
        NSDictionary *pAttributes;
        NSString *pName;
        BOOL recognized;
        // Image inputs as parameters
        result = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_MINIMUMINPUTFRAMES, 0);
        _pluginData->minFrames = result.ivalue;
        result = _pluginData->main(FF_GETPLUGINCAPS, FF_CAP_MAXIMUMINPUTFRAMES, 0);
        _pluginData->maxFrames = result.ivalue;
        for (i = 0; i < _pluginData->minFrames; i++) {
            pName = [NSString stringWithFormat:@"Input Image #%u", i];
            pAttributes = [NSDictionary dictionaryWithObjectsAndKeys:FFGLParameterTypeImage, FFGLParameterAttributeTypeKey,
                           pName, FFGLParameterAttributeNameKey, [NSNumber numberWithBool:YES], FFGLParameterAttributeRequiredKey, 
                           [NSNumber numberWithUnsignedInt:i], FFGLParameterAttributeIndexKey, nil];
            [(NSMutableDictionary *)_pluginData->parameters setObject:pAttributes forKey:pName];
        }
        for (; i < _pluginData->maxFrames; i++) {
            pName = [NSString stringWithFormat:@"Input Image #%u", i];
            pAttributes = [NSDictionary dictionaryWithObjectsAndKeys:FFGLParameterTypeImage, FFGLParameterAttributeTypeKey,
                           pName, FFGLParameterAttributeNameKey, [NSNumber numberWithBool:NO], FFGLParameterAttributeRequiredKey,
                           [NSNumber numberWithUnsignedInt:i], FFGLParameterAttributeIndexKey, nil];
            [(NSMutableDictionary *)_pluginData->parameters setObject:pAttributes forKey:pName];
        }        
        // Non-image parameters
        DWORD paramCount = _pluginData->main(FF_GETNUMPARAMETERS, 0, 0).ivalue;
        for (i = 0; i < paramCount; i++) {
            pAttributes = [NSMutableDictionary dictionaryWithCapacity:4];
            result = _pluginData->main(FF_GETPARAMETERTYPE, i, 0);
            recognized = YES;
            switch (result.ivalue) {
                case FF_TYPE_BOOLEAN:
                    [pAttributes setValue:FFGLParameterTypeBoolean forKey:FFGLParameterAttributeTypeKey];
                    result = _pluginData->main(FF_GETPARAMETERDEFAULT, i, 0);
                    [pAttributes setValue:[NSNumber numberWithBool:(result.ivalue ? YES : NO)] forKey:FFGLParameterAttributeDefaultValueKey];
                    break;
                case FF_TYPE_EVENT:
                    [pAttributes setValue:FFGLParameterTypeEvent forKey:FFGLParameterAttributeTypeKey];
                    result = _pluginData->main(FF_GETPARAMETERDEFAULT, i, 0);
                    break;
                case FF_TYPE_RED: // TODO: we may want to synthesize color inputs if we can reliably detect sets of RGBA inputs...
                case FF_TYPE_GREEN:
                case FF_TYPE_BLUE:
                case 11: // The standard defins an alpha value at 11, but it doesn't appear in the headers. Added it to my list of things to mention to FF folk...
                case FF_TYPE_STANDARD:
                case FF_TYPE_XPOS: // TODO: we may want to synthesize point inputs if we can reliably detect sets of X/YPOS inputs...
                case FF_TYPE_YPOS:
                    [pAttributes setValue:FFGLParameterTypeNumber forKey:FFGLParameterAttributeTypeKey];
                    [pAttributes setValue:[NSNumber numberWithFloat:0.0] forKey:FFGLParameterAttributeMinimumValueKey];
                    [pAttributes setValue:[NSNumber numberWithFloat:1.0] forKey:FFGLParameterAttributeMaximumValueKey];
                    result = _pluginData->main(FF_GETPARAMETERDEFAULT, i, 0);
                    [pAttributes setValue:[NSNumber numberWithFloat:result.fvalue] forKey:FFGLParameterAttributeDefaultValueKey];
                    break;
                case FF_TYPE_TEXT:
                    [pAttributes setValue:FFGLParameterTypeString forKey:FFGLParameterAttributeTypeKey];
                    result = _pluginData->main(FF_GETPARAMETERDEFAULT, i, 0);
                    if (result.svalue != NULL) {
                        [pAttributes setValue:[NSString stringWithCString:result.svalue encoding:NSASCIIStringEncoding]
                                      forKey:FFGLParameterAttributeDefaultValueKey];
                    }
                    break;
                default:
                    recognized = NO;
                    break;
            }
            if (recognized == YES) {
                result = _pluginData->main(FF_GETPARAMETERNAME, i, 0);
                if (result.svalue != NULL) {
                    [pAttributes setValue:[[[NSString alloc] initWithBytes:result.svalue length:16 encoding:NSASCIIStringEncoding] autorelease]
                                  forKey:FFGLParameterAttributeNameKey];
                } else {
                    [pAttributes setValue:@"Untitled Parameter" forKey:FFGLParameterAttributeNameKey];
                }
                [pAttributes setValue:[NSNumber numberWithBool:YES] forKey:FFGLParameterAttributeRequiredKey];
                [pAttributes setValue:[NSNumber numberWithUnsignedInt:i] forKey:FFGLParameterAttributeIndexKey];
                [(NSMutableDictionary *)_pluginData->parameters setObject:pAttributes forKey:[NSString stringWithFormat:@"non-image-parameter-%u", i]];
            }
        }
        
        // Finally initialise the plugin.
        result = _pluginData->main(FF_INITIALISE, 0, 0);
        if (result.ivalue != FF_SUCCESS) {
            pthread_mutex_unlock(&_FFGLPluginInstancesLock);
            [self release];
            return nil;
        }
        _pluginData->initted = YES;
        [_FFGLPluginInstances setObject:self forKey:path];
        pthread_mutex_unlock(&_FFGLPluginInstancesLock);
    }
    return self;
}

- (void)release
{
    pthread_mutex_lock(&_FFGLPluginInstancesLock);
    if ([self retainCount] == 1) { // ie we're about to be dealloced
        [_FFGLPluginInstances removeObjectForKey:[[self attributes] objectForKey:FFGLPluginAttributePathKey]];
    }
    [super release];
    pthread_mutex_unlock(&_FFGLPluginInstancesLock);
}

- (void)dealloc
{
    if (_pluginData != NULL) {
        if (_pluginData->initted == YES) {
            _pluginData->main(FF_DEINITIALISE, 0, 0);
        }
        if (_pluginData->bundle != NULL)
            CFRelease(_pluginData->bundle);
        [_pluginData->bufferPixelFormats release];
        [_pluginData->parameters release];
        [_pluginData->attributes release];
        [_pluginData->identifier release];
        free(_pluginData);
    }
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [self retain];
}

- (BOOL)isEqual:(id)anObject
{
    if (anObject == self) {
        return YES;
    }
    return NO;
}

- (NSUInteger) hash
{
    return [[_pluginData->attributes objectForKey:FFGLPluginAttributePathKey] hash];
}

- (FFGLPluginType)type
{
    return _pluginData->type;
}

- (FFGLPluginMode)mode
{
    return _pluginData->mode;
}

- (NSArray *)supportedBufferPixelFormats
{
    return _pluginData->bufferPixelFormats;
}

- (NSString *)identifier
{
    return _pluginData->identifier;
}

- (NSDictionary *)attributes
{
    return _pluginData->attributes;
}

- (NSArray *)parameterKeys
{
    return [_pluginData->parameters allKeys];
}

- (NSDictionary *)attributesForParameterWithKey:(NSString *)key
{
    return [_pluginData->parameters objectForKey:key];
}

#pragma mark Plugin Private for Renderers

- (NSUInteger)_minimumInputFrameCount
{
    return _pluginData->minFrames;
}

- (NSUInteger)_maximumInputFrameCount
{
    return _pluginData->maxFrames;
}

- (BOOL)_supportsSetTime
{
    return _pluginData->supportsSetTime;
}

- (BOOL)_prefersFrameCopy
{
    return (_pluginData->preferredBufferMode == FF_CAP_PREFER_COPY) || (_pluginData->preferredBufferMode == FF_CAP_PREFER_BOTH) ? YES : NO;
}

#pragma mark Instances

- (FFGLPluginInstance)_newInstanceWithBounds:(NSRect)bounds pixelFormat:(NSString *)format
{
    // TODO: lock here. I'm profiling different options to check out Ray's grumble about @synchronized and we'll settle on whatever's fastest...
    if (_pluginData->mode == FFGLPluginModeGPU) {
        FFGLViewportStruct viewport = {bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height};
        return _pluginData->main(FF_INSTANTIATEGL, (DWORD)&viewport, 0).ivalue;
    } else if (_pluginData->mode == FFGLPluginModeCPU) {
        VideoInfoStruct videoInfo;
        if ([format isEqualToString:FFGLPluginBufferPixelFormatBGRA8888] || [format isEqualToString:FFGLPluginBufferPixelFormatARGB8888])
            videoInfo.BitDepth = FF_CAP_32BITVIDEO;
        else if ([format isEqualToString:FFGLPluginBufferPixelFormatBGR888] || [format isEqualToString:FFGLPluginBufferPixelFormatRGB888])
            videoInfo.BitDepth = FF_CAP_24BITVIDEO;
        else if ([format isEqualToString:FFGLPluginBufferPixelFormatBGR565] || [format isEqualToString:FFGLPluginBufferPixelFormatRGB565])
            videoInfo.BitDepth == FF_CAP_16BITVIDEO;
        else {
            [NSException raise:@"FFGLPluginException" format:@"Unrecognized pixelFormat."];
            return 0;
        }
        videoInfo.Orientation = FF_ORIENTATION_TL; // I think ;) If it's upside down then FF_ORIENTATION_BL.
        videoInfo.FrameHeight = bounds.size.height;
        videoInfo.FrameWidth = bounds.size.width;
        return _pluginData->main(FF_INSTANTIATE, (DWORD)&videoInfo, 0).ivalue;
    } else {
        return 0; // Yikes
    }
}

- (void)_disposeInstance:(FFGLPluginInstance)instance
{
    DWORD result;
    if (_pluginData->mode == FFGLPluginModeGPU)
        result = _pluginData->main(FF_DEINSTANTIATE, 0, instance).ivalue ;
    else if (_pluginData->mode == FFGLPluginModeCPU)
        result = _pluginData->main(FF_DEINSTANTIATEGL, 0, instance).ivalue;
    else
        result = FF_FAIL;
    // As it's not clear what failure means, let's ignore it.
//    return (result == FF_FAIL ? NO : YES);
}

- (id)_valueForNonImageParameterKey:(NSString *)key ofInstance:(FFGLPluginInstance)instance
{
    if (![[self parameterKeys] containsObject:key]) {
        [NSException raise:@"FFGLPluginException" format:@"No such key: %@", key];
        return nil;
    }
    NSDictionary *pattributes = [self attributesForParameterWithKey:key];
    NSUInteger pindex = [[pattributes objectForKey:FFGLParameterAttributeIndexKey] unsignedIntValue];
    plugMainUnion result = _pluginData->main(FF_GETPARAMETER, pindex, instance);
    if ([[pattributes objectForKey:FFGLParameterAttributeTypeKey] isEqualToString:FFGLParameterTypeString]) {
        return [NSString stringWithCString:result.svalue encoding:NSASCIIStringEncoding];
    } else {
        return [NSNumber numberWithFloat:result.fvalue];
    }
}

- (void)_setValue:(id)value forNonImageParameterKey:(NSString *)key ofInstance:(FFGLPluginInstance)instance
{
    if (![[self parameterKeys] containsObject:key]) {
        [NSException raise:@"FFGLPluginException" format:@"No such key: %@", key];
        return;
    }
    NSDictionary *pattributes = [self attributesForParameterWithKey:key];
    NSUInteger pindex = [[pattributes objectForKey:FFGLParameterAttributeIndexKey] unsignedIntValue];
    SetParameterStruct param;
    param.ParameterNumber = pindex;
    if ([[pattributes objectForKey:FFGLParameterAttributeTypeKey] isEqualToString:FFGLParameterTypeString]) {
        param.NewParameterValue = (DWORD)[(NSString *)value cStringUsingEncoding:NSASCIIStringEncoding];
    } else {
        *((float *)(unsigned)&param.NewParameterValue) = [(NSNumber *)value floatValue]; // ? Check this...
    }
    _pluginData->main(FF_SETPARAMETER, (DWORD)&param, instance);
}

- (void)_setTime:(NSTimeInterval)time ofInstance:(FFGLPluginInstance)instance
{
    _pluginData->main(FF_SETTIME, (DWORD)&time, instance);
}

- (void)_processFrameCopy:(ProcessFrameCopyStruct *)frameInfo forInstance:(FFGLPluginInstance)instance
{
    _pluginData->main(FF_PROCESSFRAMECOPY, (DWORD)frameInfo, instance);
}

- (void)_processFrameInPlace:(void *)buffer forInstance:(FFGLPluginInstance)instance
{
    _pluginData->main(FF_PROCESSFRAME, (DWORD)buffer, instance);
}
@end