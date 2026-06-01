#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <dlfcn.h>

@interface HotspotProbe : NSObject
@property(nonatomic, strong) id session;
@property(nonatomic, copy) NSString *targetName;
@property(nonatomic, copy) NSString *lastEnableError;
@property(nonatomic, copy) void (^completion)(id hotspotInfo, id error);
@property(nonatomic) BOOL didRequestEnable;
@end

static void PrintLine(NSString *key, NSString *value) {
    printf("%s=%s\n", key.UTF8String, value.UTF8String);
}

static void ExitWithResult(BOOL success, BOOL didReconnect, NSString *message, NSString *networkName, NSString *password) {
    PrintLine(@"success", success ? @"1" : @"0");
    PrintLine(@"didReconnect", didReconnect ? @"1" : @"0");
    PrintLine(@"message", message ?: @"");
    if (networkName.length > 0) {
        PrintLine(@"networkName", networkName);
    }
    if (password.length > 0) {
        PrintLine(@"password", password);
    }
    fflush(stdout);
    fflush(stderr);
    _exit(success ? 0 : 1);
}

@implementation HotspotProbe

- (void)updatedFoundDeviceList:(id)devices {
    [self handleDevices:devices];
}

- (void)session:(id)session updatedFoundDevices:(id)devices {
    [self handleDevices:devices];
}

- (void)handleDevices:(id)devices {
    if (self.didRequestEnable) {
        return;
    }

    for (id device in devices) {
        NSString *deviceName = nil;
        @try {
            deviceName = [device valueForKey:@"deviceName"];
        } @catch (__unused NSException *exception) {
            continue;
        }
        deviceName = [deviceName precomposedStringWithCanonicalMapping];

        if (self.targetName.length > 0 && ![deviceName isEqualToString:self.targetName]) {
            continue;
        }

        self.didRequestEnable = YES;
        [self requestEnableForDevice:device selectorIndex:0];
        return;
    }
}

- (void)requestEnableForDevice:(id)device selectorIndex:(NSUInteger)selectorIndex {
    NSArray<NSString *> *selectorNames = @[
        @"enableRemoteHotspotForDevice:withCompletionHandler:",
        @"enableHotspotForDevice:withCompletionHandler:"
    ];

    if (selectorIndex >= selectorNames.count) {
        ExitWithResult(
            NO,
            NO,
            self.lastEnableError ?: @"Instant Hotspot did not return Wi-Fi credentials.",
            nil,
            nil
        );
    }

    SEL selector = NSSelectorFromString(selectorNames[selectorIndex]);
    if (![self.session respondsToSelector:selector]) {
        [self requestEnableForDevice:device selectorIndex:selectorIndex + 1];
        return;
    }

    __weak HotspotProbe *weakSelf = self;
    self.completion = ^(id hotspotInfo, id error) {
        HotspotProbe *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        NSString *networkName = nil;
        NSString *password = nil;

        if ([hotspotInfo isKindOfClass:NSString.class] && [error isKindOfClass:NSString.class]) {
            networkName = hotspotInfo;
            password = error;
        } else if (hotspotInfo) {
            @try {
                networkName = [hotspotInfo valueForKey:@"name"];
                password = [hotspotInfo valueForKey:@"password"];
            } @catch (__unused NSException *exception) {}
        }

        if (networkName.length > 0 && password.length > 0) {
            ExitWithResult(YES, NO, @"Instant Hotspot credentials received.", networkName, password);
        }

        NSString *message = @"Instant Hotspot did not return Wi-Fi credentials.";
        if ([error isKindOfClass:NSError.class]) {
            message = [(NSError *)error localizedDescription];
        } else if (error) {
            message = [error description];
        }
        strongSelf.lastEnableError = message;
        [strongSelf requestEnableForDevice:device selectorIndex:selectorIndex + 1];
    };

    ((void (*)(id, SEL, id, id))objc_msgSend)(
        self.session,
        selector,
        device,
        self.completion
    );
}

@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *targetName = nil;
        if (argc > 1) {
            targetName = [NSString stringWithUTF8String:argv[1]];
        }
        if (targetName.length == 0) {
            ExitWithResult(NO, NO, @"Expected a hotspot device name.", nil, nil);
        }

        if (dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) == NULL) {
            ExitWithResult(NO, NO, @"Instant Hotspot private API is unavailable.", nil, nil);
        }

        Class sessionClass = NSClassFromString(@"SFRemoteHotspotSession");
        if (!sessionClass) {
            ExitWithResult(NO, NO, @"Instant Hotspot session class is unavailable.", nil, nil);
        }

        HotspotProbe *probe = [HotspotProbe new];
        probe.targetName = [targetName precomposedStringWithCanonicalMapping];
        id session = [sessionClass new];
        probe.session = session;

        ((void (*)(id, SEL, id))objc_msgSend)(session, @selector(setDelegate:), probe);
        ((void (*)(id, SEL))objc_msgSend)(session, @selector(startBrowsing));

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            ExitWithResult(
                NO,
                NO,
                [NSString stringWithFormat:@"%@ is not visible to Instant Hotspot.", targetName],
                nil,
                nil
            );
        });
        dispatch_main();
    }
}
