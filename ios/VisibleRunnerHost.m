#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

static const uint16_t IPUPairingRelayPort = 12005;

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

static BOOL IPUSendAll(int fd, const uint8_t *bytes, size_t length) {
    size_t sent = 0;
    while (sent < length) {
        ssize_t count = send(fd, bytes + sent, length - sent, 0);
        if (count <= 0) return NO;
        sent += (size_t)count;
    }
    return YES;
}

static int IPUConnectLocalRemotePairing(void) {
    for (uint16_t port = 49152; port <= 49167; port++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) continue;
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct sockaddr_in target = {0};
        target.sin_len = sizeof(target);
        target.sin_family = AF_INET;
        target.sin_port = htons(port);
        target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (struct sockaddr *)&target, sizeof(target)) == 0) {
            NSLog(@"ipu-visible-host: pairing relay connected to loopback:%u", port);
            return fd;
        }
        close(fd);
    }
    return -1;
}

static void IPURelayConnectionToRemotePairing(int client) {
    int upstream = IPUConnectLocalRemotePairing();
    if (upstream < 0) {
        NSLog(@"ipu-visible-host: no local RemotePairing service on 49152-49167");
        close(client);
        return;
    }
    uint8_t buffer[65536];
    while (1) {
        fd_set reads;
        FD_ZERO(&reads);
        FD_SET(client, &reads);
        FD_SET(upstream, &reads);
        int highest = MAX(client, upstream);
        int result = select(highest + 1, &reads, NULL, NULL, NULL);
        if (result <= 0) break;
        int source = FD_ISSET(client, &reads) ? client : upstream;
        int destination = source == client ? upstream : client;
        ssize_t count = recv(source, buffer, sizeof(buffer), 0);
        if (count <= 0 || !IPUSendAll(destination, buffer, (size_t)count)) break;
    }
    close(upstream);
    close(client);
    NSLog(@"ipu-visible-host: pairing relay connection closed");
}

static int IPUConnectLocalLockdown(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_in target = {0};
    target.sin_len = sizeof(target);
    target.sin_family = AF_INET;
    target.sin_port = htons(62078);
    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&target, sizeof(target)) == 0) {
        NSLog(@"ipu-visible-host: lockdown relay connected to loopback:62078");
        return fd;
    }
    close(fd);
    return -1;
}

static void IPURelayConnectionToLockdown(int client) {
    int upstream = IPUConnectLocalLockdown();
    if (upstream < 0) {
        NSLog(@"ipu-visible-host: local lockdownd service unavailable");
        close(client);
        return;
    }
    uint8_t buffer[65536];
    while (1) {
        fd_set reads;
        FD_ZERO(&reads);
        FD_SET(client, &reads);
        FD_SET(upstream, &reads);
        int highest = MAX(client, upstream);
        int result = select(highest + 1, &reads, NULL, NULL, NULL);
        if (result <= 0) break;
        int source = FD_ISSET(client, &reads) ? client : upstream;
        int destination = source == client ? upstream : client;
        ssize_t count = recv(source, buffer, sizeof(buffer), 0);
        if (count <= 0 || !IPUSendAll(destination, buffer, (size_t)count)) break;
    }
    close(upstream);
    close(client);
    NSLog(@"ipu-visible-host: lockdown relay connection closed");
}

static void IPUStartPairingRelay(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) {
            NSLog(@"ipu-visible-host: relay socket failed errno=%d", errno);
            return;
        }
        int yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(IPUPairingRelayPort);
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(server, 4) != 0) {
            NSLog(@"ipu-visible-host: relay bind/listen failed errno=%d", errno);
            close(server);
            return;
        }
        NSLog(@"ipu-visible-host: pairing relay listening on %u", IPUPairingRelayPort);
        while (1) {
            int client = accept(server, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR) continue;
                break;
            }
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                IPURelayConnectionToRemotePairing(client);
            });
        }
        close(server);
    });
}

static void IPUStartReversePairingRelay(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (1) {
            int bridge = socket(AF_INET, SOCK_STREAM, 0);
            if (bridge >= 0) {
                int yes = 1;
                setsockopt(bridge, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
                struct sockaddr_in windows = {0};
                windows.sin_len = sizeof(windows);
                windows.sin_family = AF_INET;
                windows.sin_port = htons(IPUPairingRelayPort);
                inet_pton(AF_INET, "100.114.29.8", &windows.sin_addr);
                if (connect(bridge, (struct sockaddr *)&windows, sizeof(windows)) == 0) {
                    NSLog(@"ipu-visible-host: reverse pairing relay connected to Windows");
                    IPURelayConnectionToRemotePairing(bridge);
                    sleep(1);
                    continue;
                }
                close(bridge);
            }
            sleep(2);
        }
    });
}

static void IPUStartReverseLockdownRelay(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (1) {
            int bridge = socket(AF_INET, SOCK_STREAM, 0);
            if (bridge >= 0) {
                int yes = 1;
                setsockopt(bridge, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
                struct sockaddr_in windows = {0};
                windows.sin_len = sizeof(windows);
                windows.sin_family = AF_INET;
                windows.sin_port = htons(12007);
                inet_pton(AF_INET, "100.114.29.8", &windows.sin_addr);
                if (connect(bridge, (struct sockaddr *)&windows, sizeof(windows)) == 0) {
                    NSLog(@"ipu-visible-host: reverse lockdown relay connected to Windows");
                    IPURelayConnectionToLockdown(bridge);
                    sleep(1);
                    continue;
                }
                close(bridge);
            }
            sleep(2);
        }
    });
}

static int IPUConnectLocalService(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_in target = {0};
    target.sin_len = sizeof(target);
    target.sin_family = AF_INET;
    target.sin_port = htons(port);
    target.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&target, sizeof(target)) == 0) return fd;
    close(fd);
    return -1;
}

static void IPURelayExistingService(int bridge, uint16_t localPort) {
    int upstream = IPUConnectLocalService(localPort);
    if (upstream < 0) {
        close(bridge);
        return;
    }
    NSLog(@"ipu-visible-host: relaying local port %u", localPort);
    uint8_t buffer[65536];
    while (1) {
        fd_set reads;
        FD_ZERO(&reads);
        FD_SET(bridge, &reads);
        FD_SET(upstream, &reads);
        int highest = MAX(bridge, upstream);
        int result = select(highest + 1, &reads, NULL, NULL, NULL);
        if (result <= 0) break;
        int source = FD_ISSET(bridge, &reads) ? bridge : upstream;
        int destination = source == bridge ? upstream : bridge;
        ssize_t count = recv(source, buffer, sizeof(buffer), 0);
        if (count <= 0 || !IPUSendAll(destination, buffer, (size_t)count)) break;
    }
    close(upstream);
    close(bridge);
}

static void IPUStartReverseServiceRelay(uint16_t localPort, uint16_t windowsPort) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (1) {
            int bridge = socket(AF_INET, SOCK_STREAM, 0);
            if (bridge >= 0) {
                int yes = 1;
                setsockopt(bridge, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
                struct sockaddr_in windows = {0};
                windows.sin_len = sizeof(windows);
                windows.sin_family = AF_INET;
                windows.sin_port = htons(windowsPort);
                inet_pton(AF_INET, "100.114.29.8", &windows.sin_addr);
                if (connect(bridge, (struct sockaddr *)&windows, sizeof(windows)) == 0) {
                    IPURelayExistingService(bridge, localPort);
                    sleep(1);
                    continue;
                }
                close(bridge);
            }
            sleep(2);
        }
    });
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
        ? @"Starting authenticated control and video services…"
        : @"Control, video, and secure-pairing relays are connecting to the Windows host. Keep this screen open while secure pairing completes.";

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
    [self startDeviceLinkedAnimationWithTitle:title status:status];
    [self startLocalNetworkProbe];
    IPUStartPairingRelay();
    IPUStartReversePairingRelay();
    IPUStartReverseLockdownRelay();
    IPUStartReverseServiceRelay(8100, 18100);
    IPUStartReverseServiceRelay(9100, 19100);

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
        NSLog(@"ipu-visible-host: normal launch; pairing relay ready");
    }
    return YES;
}

- (void)startDeviceLinkedAnimationWithTitle:(UILabel *)title status:(UILabel *)status {
    title.text = @"Device Linked";
    status.text = @"Starting authenticated control and video services…";
    title.transform = CGAffineTransformMakeScale(0.92, 0.92);
    title.alpha = 0.45;
    [UIView animateWithDuration:0.65 delay:0.0 options:UIViewAnimationOptionAutoreverse |
        UIViewAnimationOptionRepeat | UIViewAnimationOptionAllowUserInteraction animations:^{
        title.transform = CGAffineTransformMakeScale(1.04, 1.04);
        title.alpha = 1.0;
    } completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.25 animations:^{
            title.alpha = 1.0;
            status.alpha = 1.0;
        }];
    });
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
