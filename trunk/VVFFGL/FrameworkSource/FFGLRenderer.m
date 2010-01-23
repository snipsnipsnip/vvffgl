//
//  FFGLRenderer.m
//  VVOpenSource
//
//  Created by Tom on 24/07/2009.
//

#import "FFGLRenderer.h"
#import "FFGLPlugin.h"
#import "FFGLGPURenderer.h"
#import "FFGLCPURenderer.h"
#import "FFGLInternal.h"

enum FFGLRendererReadyState {
    FFGLRendererNeedsCheck,
    FFGLRendererNotReady,
    FFGLRendererReady
};

@interface FFGLRendererParametersBindable : NSObject
{
    FFGLRenderer *_renderer;
}
- (id)initWithRenderer:(FFGLRenderer *)renderer;
@end

@interface FFGLRenderer (Private)
- (void)_performSetValue:(id)value forParameterKey:(NSString *)key;
@end
@implementation FFGLRenderer

- (id)init
{
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (id)initWithPlugin:(FFGLPlugin *)plugin context:(CGLContextObj)context pixelFormat:(NSString *)format outputHint:(FFGLRendererHint)hint size:(NSSize)size
{
    if (self = [super init])
	{
        if ([self class] == [FFGLRenderer class])
		{
            [self release];
            if ([plugin mode] == FFGLPluginModeGPU)
			{
                return [[FFGLGPURenderer alloc] initWithPlugin:plugin context:context pixelFormat:format outputHint:hint size:size];
            }
			else if ([plugin mode] == FFGLPluginModeCPU)
			{
                return [[FFGLCPURenderer alloc] initWithPlugin:plugin context:context pixelFormat:format outputHint:hint size:size];
            } 
			else
			{
                return nil;
            }        
        }
		else
		{
            if ((plugin == nil)
                || (([plugin mode] == FFGLPluginModeCPU)
                    && ![[plugin supportedBufferPixelFormats] containsObject:format])
				|| (hint > FFGLRendererHintBuffer)
				)
			{
				[self release];
                [NSException raise:@"FFGLRendererException" format:@"Invalid arguments in init"];
                return nil;
            }
            
			NSUInteger maxInputs = [plugin _maximumInputFrameCount];
            _imageInputValidity = malloc(sizeof(BOOL) * maxInputs);
            _readyState = FFGLRendererNeedsCheck;
            
			if (_imageInputValidity == NULL) 
			{
                [self release];
                return nil;
            }
			
            NSUInteger i;
            for (i = 0; i < maxInputs; i++)
			{
                _imageInputValidity[i] = NO;
            }
            _instance = [plugin _newInstanceWithSize:size pixelFormat:format];
            
			if (_instance == 0)
			{
                [self release];
                return nil;
            }
            _plugin = [plugin retain];
			
            if (context != NULL)
			{
                _context = CGLRetainContext(context);                
            }
            _size = size;
            _pixelFormat = [format retain];
            _imageInputs = [[NSMutableDictionary alloc] initWithCapacity:4];
			
            if (pthread_mutex_init(&_lock, NULL) != 0)
			{
                [self release];
                return nil;
            }
			_outputHint = hint;
			_paramsBindableCreationLock = OS_SPINLOCK_INIT;
        }
    }	
    return self;
}

- (void)releaseResources {
    if(_context != nil)
        CGLReleaseContext(_context);
    if (_instance != 0)
        [[self plugin] _disposeInstance:_instance];
    if (_imageInputValidity != NULL)
        free(_imageInputValidity);
    pthread_mutex_destroy(&_lock);
}

- (void)finalize
{
    [self releaseResources];
    [super finalize];
}

- (void)dealloc
{
    [_params release];
    [_plugin release];
    [_pixelFormat release];
    [_imageInputs release];
	[_output release];
    [self releaseResources];
    [super dealloc];
}

- (FFGLPlugin *)plugin
{
    return _plugin;
}

- (CGLContextObj)context
{
    return _context;
}

- (NSSize)size
{
    return _size;
}

- (NSString *)pixelFormat
{
    return _pixelFormat;
}

- (FFGLRendererHint)outputHint
{
    return _outputHint;
}

- (BOOL)willUseParameterKey:(NSString *)key
{
    NSDictionary *attributes = [_plugin attributesForParameterWithKey:key];
    if (attributes == nil) {
        [NSException raise:@"FFGLRendererException" format:@"No such key: %@"];
        return NO;
    }
    if ([[attributes objectForKey:FFGLParameterAttributeTypeKey] isEqualToString:FFGLParameterTypeImage]) {
        NSUInteger index = [[attributes objectForKey:FFGLParameterAttributeIndexKey] unsignedIntValue];
        NSUInteger min = [_plugin _minimumInputFrameCount];
        if (index < min) {
            return YES;
        }
        pthread_mutex_lock(&_lock);
        BOOL result = [_plugin _imageInputAtIndex:index willBeUsedByInstance:_instance];
        pthread_mutex_unlock(&_lock);
		return result;
    } else {
        return YES;
    }
}

- (id)valueForParameterKey:(NSString *)key
{
    id output;
    pthread_mutex_lock(&_lock);
    if ([[[_plugin attributesForParameterWithKey:key] objectForKey:FFGLParameterAttributeTypeKey] isEqualToString:FFGLParameterTypeImage]) {
        output = [_imageInputs objectForKey:key];
    } else {
        output = [_plugin _valueForNonImageParameterKey:key ofInstance:_instance];
    }
    pthread_mutex_unlock(&_lock);
    return output;
}

- (void)setValue:(id)value forParameterKey:(NSString *)key
{
    [_params willChangeValueForKey:key];
    [self _performSetValue:value forParameterKey:key];
    [_params didChangeValueForKey:key];
}

- (void)_performSetValue:(id)value forParameterKey:(NSString *)key
{
    NSDictionary *attributes = [_plugin attributesForParameterWithKey:key];
    if (attributes == nil) {
        [NSException raise:@"FFGLRendererException" format:@"No such key: %@"];
        return;
    }
    NSUInteger index = [[attributes objectForKey:FFGLParameterAttributeIndexKey] unsignedIntValue];
    NSString *type = [attributes objectForKey:FFGLParameterAttributeTypeKey];
    pthread_mutex_lock(&_lock);
    if ([type isEqualToString:FFGLParameterTypeImage])
    {
        // check our subclass can use the image
        BOOL validity;
        if (value != nil) {
            validity = [self _implementationSetImage:value forInputAtIndex:index];
            [_imageInputs setObject:value forKey:key];
        } else {
            validity = NO;
            [_imageInputs removeObjectForKey:key];
        }
        if (_imageInputValidity[index] != validity)
        {
            _imageInputValidity[index] = validity;
            _readyState = FFGLRendererNeedsCheck;
        }
    }
    else if ([type isEqualToString:FFGLParameterTypeString])
    {
        [_plugin _setValue:value forStringParameterAtIndex:index ofInstance:_instance];
        _readyState = FFGLRendererNeedsCheck;
    }
    else
    {
        [_plugin _setValue:value forNumberParameterAtIndex:index ofInstance:_instance];
        _readyState = FFGLRendererNeedsCheck;
    }
    pthread_mutex_unlock(&_lock);
}

- (id)parameters
{
    OSSpinLockLock(&_paramsBindableCreationLock);
    if (_params == nil)
    {
        _params = [[FFGLRendererParametersBindable alloc] initWithRenderer:self]; // released in dealloc
    }
    OSSpinLockUnlock(&_paramsBindableCreationLock);
    return _params;
}

- (FFGLImage *)outputImage
{
    return _output;
}

- (void)setOutputImage:(FFGLImage *)image
{
    // This is called by subclasses from _implementationRender, so we already have the lock.
    [image retain];
    [_output release];
    _output = image;
}

- (BOOL)renderAtTime:(NSTimeInterval)time
{
    BOOL success;
    pthread_mutex_lock(&_lock);
    if (_readyState == FFGLRendererNeedsCheck)
    {
        NSUInteger i;
        NSUInteger min = [_plugin _minimumInputFrameCount];
        NSUInteger max = [_plugin _maximumInputFrameCount];
        NSUInteger got = 0;
        _readyState = FFGLRendererReady;
        for (i = 0; i < min; i++) {
            if (_imageInputValidity[i] == NO) {
                _readyState = FFGLRendererNotReady;
                break;
            }
            got++;
        }
        for (; i < max; i++) {
            if ((_imageInputValidity[i] == NO) && [_plugin _imageInputAtIndex:i willBeUsedByInstance:_instance]) {
                _readyState = FFGLRendererNotReady;
                break;
            }
            got++;
        }
        [self _implementationSetImageInputCount:got];
    }
    if (_readyState == FFGLRendererReady)
	{
        if ([_plugin _supportsSetTime])
		{
            [_plugin _setTime:time ofInstance:_instance];
        }
        success = [self _implementationRender];        
    }
	else 
	{
        success = NO;
    }
	if (success == NO)
	{
		[self setOutputImage:nil];
	}
    pthread_mutex_unlock(&_lock);
    return success;
}
@end

@implementation FFGLRendererParametersBindable
- (id)initWithRenderer:(FFGLRenderer *)renderer
{
    if (self = [super init])
    {
	/* Don't retain the renderer, or it will never be released */
        _renderer = renderer;
    }
    return self;
}

- (id)valueForUndefinedKey:(NSString *)key
{
    if ([[[_renderer plugin] parameterKeys] containsObject:key])
        return [_renderer valueForParameterKey:key];
    else
        return [super valueForUndefinedKey:key];
}


- (void)setValue:(id)value forUndefinedKey:(NSString *)key
{
    if ([[[_renderer plugin] parameterKeys] containsObject:key])
        [_renderer _performSetValue:value forParameterKey:key];
    else
        [super setValue:value forUndefinedKey:key];
}

@end