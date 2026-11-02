#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>

static BOOL IPUHasXCTestLaunchEnvironment(void) {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    for (NSString *key in environment) {
        if ([key containsString:@"XCTest"] || [key containsString:@"XCInjectBundle"]) {
            return YES;
        }
    }
    return NO;
}

static void *IPUOpenXCTest(void) {
    const char *paths[] = {
        "/Developer/Library/Frameworks/XCTest.framework/XCTest",
        "/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
        "@rpath/XCTest.framework/XCTest",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        void *handle = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (handle) return handle;
        NSLog(@"ipu-visible-host: dlopen %s failed: %s", paths[i], dlerror());
    }
    return NULL;
}

@interface IPUVisibleHostDelegate : UIResponder <UIApplicationDelegate, NSNetServiceBrowserDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NSNetServiceBrowser *browser;
@end

@implementation IPUVisibleHostDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.047 blue:0.071 alpha:1.0];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"iPhone Use Remote";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:28.0];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.textColor = [UIColor colorWithWhite:0.82 alpha:1.0];
    status.font = [UIFont systemFontOfSize:17.0];
    status.textAlignment = NSTextAlignmentCenter;
    status.numberOfLines = 0;
    status.text = IPUHasXCTestLaunchEnvironment()
        ? @"Starting the authenticated control and video services…"
        : @"Installed and ready. Keep this app installed. Start it from the paired Windows automation host to open ports 8100 and 9100.";

    [controller.view addSubview:title];
    [controller.view addSubview:status];
    [NSLayoutConstraint activateConstraints:@[
        [title.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor constant:-50.0],
        [status.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:24.0],
        [status.leadingAnchor constraintEqualToAnchor:controller.view.leadingAnchor constant:28.0],
        [status.trailingAnchor constraintEqualToAnchor:controller.view.trailingAnchor constant:-28.0],
    ]];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    [self startLocalNetworkProbe];

    if (IPUHasXCTestLaunchEnvironment()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void *handle = IPUOpenXCTest();
            void (*xctestMain)(id) = handle ? (void (*)(id))dlsym(handle, "_XCTestMain") : NULL;
            if (!xctestMain) {
                NSLog(@"ipu-visible-host: _XCTestMain unavailable");
                return;
            }
            NSLog(@"ipu-visible-host: starting _XCTestMain");
            xctestMain(nil);
        });
    } else {
        NSLog(@"ipu-visible-host: normal launch; waiting for an XCTest host session");
    }
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self startLocalNetworkProbe];
}

- (void)startLocalNetworkProbe {
    [self.browser stop];
    self.browser = [NSNetServiceBrowser new];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_iphoneuse._tcp." inDomain:@"local."];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didNotSearch:(NSDictionary *)errorDict {
    NSLog(@"ipu-visible-host: local network probe error %@", errorDict);
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(IPUVisibleHostDelegate.class));
    }
}
