import UIKit
import Foundation
import Darwin
import WebKit

private enum RelayConfig {
    static let defaultHosts = ["100.114.29.8", "msi.tail28f016.ts.net", "100.94.142.66"]
    static let pairingPort: UInt16 = 12005
    static let deviceUDID = "00008140-0004115A3406801C"
    // Keep relay reads bounded so a stalled peer cannot monopolize the socket loop.
    static let relayChunkSize = 16 * 1024
}

private func hosts() -> [String] {
    let value = ProcessInfo.processInfo.environment["IPU_WINDOWS_HOSTS"] ?? ""
    let parsed = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return parsed.isEmpty ? RelayConfig.defaultHosts : parsed
}
private func log(_ s: String) { NSLog("ipu-visible-host-swift: %@", s) }
private final class RelayHealth {
    static let shared = RelayHealth()
    private let lock = NSLock()
    private var states: [String: String] = [:]
    func set(_ key: String, _ value: String) {
        lock.lock(); states[key] = value; lock.unlock()
    }
    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return states.keys.sorted().compactMap { key in states[key].map { "\(key): \($0)" } }.joined(separator: "\n")
    }
}
private func tune(_ fd: Int32) {
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
}
private func dial(_ host: String, _ port: UInt16, _ seconds: TimeInterval = 2.5) -> Int32 {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    let lookup: Int32 = host.withCString { hostPtr in
        String(port).withCString { portPtr in getaddrinfo(hostPtr, portPtr, &hints, &result) }
    }
    guard lookup == 0, let info = result else { return -1 }
    defer { freeaddrinfo(info) }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    tune(fd)
    let old = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, old | O_NONBLOCK)
    if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
        _ = fcntl(fd, F_SETFL, old); return fd
    }
    guard errno == EINPROGRESS else { close(fd); return -1 }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let milliseconds = Int32(max(1, Int(seconds * 1_000)))
    guard Darwin.poll(&descriptor, 1, milliseconds) > 0 else { close(fd); return -1 }
    var errorCode: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &errorCode, &length)
    guard errorCode == 0 else { close(fd); return -1 }
    _ = fcntl(fd, F_SETFL, old); return fd
}
private func loopback(_ port: UInt16) -> Int32 {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian; a.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
    let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return -1 }; tune(fd)
    let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if ok == 0 { return fd }; close(fd); return -1
}
private func pairingUpstream() -> Int32 {
    for p in UInt16(49152)...UInt16(49167) {
        let fd = loopback(p)
        if fd >= 0 { log("RemotePairing connected on loopback:\(p)"); return fd }
    }
    return -1
}
private func sendAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
    var sent = 0
    while sent < count {
        let n = send(fd, pointer.advanced(by: sent), count - sent, 0)
        if n < 0, errno == EINTR { continue }; if n <= 0 { return false }; sent += n
    }
    return true
}
private func relay(_ a: Int32, _ b: Int32) {
    var buffer = [UInt8](repeating: 0, count: RelayConfig.relayChunkSize)
    while true {
        var descriptors = [
            pollfd(fd: a, events: Int16(POLLIN), revents: 0),
            pollfd(fd: b, events: Int16(POLLIN), revents: 0)
        ]
        guard Darwin.poll(&descriptors, 2, -1) > 0 else { break }
        let mask = Int16(POLLIN | POLLHUP | POLLERR)
        let source = (descriptors[0].revents & mask) != 0 ? a : b
        let destination = source == a ? b : a
        let count = buffer.withUnsafeMutableBytes { recv(source, $0.baseAddress, $0.count, 0) }
        guard count > 0, buffer.withUnsafeBytes({ raw in
            guard let base = raw.baseAddress else { return false }
            return sendAll(destination, base, count)
        }) else { break }
    }
    close(a); close(b)
}
private func requestRunnerStatus(completion: @escaping (Bool, String) -> Void = { _, _ in }) {
    // Ask the MSI relay to refresh the configured runner state. This is a
    // read-only HTTP request; iOS cannot launch an XCTest/WDA runner itself.
    DispatchQueue.global(qos: .utility).async {
        let path = "/api/ui/stream-status?udid=\(RelayConfig.deviceUDID)"
        for host in hosts() {
            let fd = dial(host, 8765, 1.5)
            guard fd >= 0 else { continue }
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            let sent = request.data(using: .utf8).map { data in
                data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return false }
                    return sendAll(fd, base, raw.count)
                }
            } ?? false
            guard sent else { close(fd); continue }
            var waiter = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&waiter, 1, 1_000) > 0 {
                var response = [UInt8](repeating: 0, count: 512)
                let count = response.withUnsafeMutableBytes { raw in
                    recv(fd, raw.baseAddress, raw.count, 0)
                }
                if count > 0 {
                    let line = String(bytes: response.prefix(count), encoding: .utf8)?
                        .split(separator: "\n", maxSplits: 1).first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HTTP response"
                    let ready = line.contains(" 200 ") || line.contains(" 204 ")
                    RelayHealth.shared.set("runner-request", "\(host): \(line)")
                    log("runner status requested from \(host): \(line)")
                    DispatchQueue.main.async { completion(ready, line) }
                    close(fd)
                    return
                }
            } else {
                RelayHealth.shared.set("runner-request", "\(host): timeout")
            }
            close(fd)
        }
        RelayHealth.shared.set("runner-request", "no relay reachable")
        log("runner status request could not reach an MSI relay")
        DispatchQueue.main.async { completion(false, "No runner response from MSI") }
    }
}

private func startInboundPairing() {
    DispatchQueue.global(qos: .userInitiated).async {
        let server = socket(AF_INET, SOCK_STREAM, 0); guard server >= 0 else { return }; tune(server)
        var one: Int32 = 1; setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = RelayConfig.pairingPort.bigEndian; a.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(server, 8) == 0 else { close(server); log("pairing bind/listen failed"); return }
        log("pairing relay listening on \(RelayConfig.pairingPort)")
        while true {
            let client = accept(server, nil, nil); if client < 0 { if errno == EINTR { continue }; break }; tune(client)
            DispatchQueue.global(qos: .userInitiated).async {
                let upstream = pairingUpstream(); if upstream >= 0 { relay(client, upstream) } else { close(client); log("no local RemotePairing service") }
            }
        }
        close(server)
    }
}
private func startReverse(localPort: UInt16?, remotePort: UInt16) {
    DispatchQueue.global(qos: .userInitiated).async {
        var delay: UInt32 = 1
        var preferredHost: String?
        while true {
            let configuredHosts = hosts()
            let candidates = preferredHost.map { preferred in
                [preferred] + configuredHosts.filter { $0 != preferred }
            } ?? configuredHosts
            var worked = false
            for host in candidates {
                RelayHealth.shared.set("\(remotePort)", "trying \(host)")
                let bridge = dial(host, remotePort)
                if bridge < 0 { continue }
                let upstream: Int32 = localPort == nil
                    ? (remotePort == RelayConfig.pairingPort ? pairingUpstream() : loopback(62078))
                    : localPort.map { loopback($0) } ?? -1
                guard upstream >= 0 else {
                    close(bridge)
                    RelayHealth.shared.set("\(remotePort)", "local upstream unavailable")
                    continue
                }
                worked = true
                delay = 1
                preferredHost = host
                RelayHealth.shared.set("\(remotePort)", "connected via \(host)")
                log("connected to \(host):\(remotePort)")
                relay(bridge, upstream)
                break
            }
            if worked {
                sleep(1)
            } else {
                RelayHealth.shared.set("\(remotePort)", "retrying in \(delay)s")
                log("no complete path for \(remotePort); retry in \(delay)s")
                sleep(delay)
                delay = min(delay * 2, 8)
            }
        }
    }
}

private final class HostController: UIViewController {
    var starting = true
    override var prefersStatusBarHidden: Bool { starting }
}
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var healthLabel: UILabel?
    var healthTimer: Timer?
    private var runnerPromptPresented = false

    private func requestAndPromptForRunner() {
        requestRunnerStatus { [weak self] ready, detail in
            guard let self, !ready else { return }
            self.presentRunnerPrompt(detail)
        }
    }

    private func presentRunnerPrompt(_ detail: String) {
        guard !runnerPromptPresented,
              let presenter = window?.rootViewController,
              presenter.presentedViewController == nil else { return }
        runnerPromptPresented = true
        let alert = UIAlertController(
            title: "Start WebDriverAgent",
            message: "The relay app is running, but WebDriverAgent has not answered. Start WebDriverAgentRunner with your Xcode/Appium/CoreDevice launcher, then tap Retry.\n\nStatus: \(detail)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.runnerPromptPresented = false
            self?.requestAndPromptForRunner()
        })
        alert.addAction(UIAlertAction(title: "WebKit Instructions", style: .default) { [weak self] _ in
            self?.runnerPromptPresented = false
            self?.presentWebKitInstructions()
        })
        alert.addAction(UIAlertAction(title: "Later", style: .cancel) { [weak self] _ in
            self?.runnerPromptPresented = false
        })
        presenter.present(alert, animated: true)
    }

    private func presentWebKitInstructions() {
        guard let url = URL(string: "https://appium.github.io/appium-xcuitest-driver/latest/guides/run-preinstalled-wda/") else { return }
        let page = UIViewController()
        page.view.backgroundColor = .black
        page.title = "WebDriverAgent Setup"
        let web = WKWebView(frame: page.view.bounds)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        page.view.addSubview(web)
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(dismissWebKitInstructions)
        )
        let nav = UINavigationController(rootViewController: page)
        window?.rootViewController?.present(nav, animated: true) {
            web.load(URLRequest(url: url))
        }
    }

    @objc private func dismissWebKitInstructions() {
        window?.rootViewController?.dismiss(animated: true)
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Keep the relay visually quiet: no persistent status overlay or popup.
        // Continuous socket service still requires the app to remain active under iOS lifecycle rules.
        let vc = HostController(); vc.view.backgroundColor = .black
        let w = UIWindow(frame: UIScreen.main.bounds); w.rootViewController = vc; w.makeKeyAndVisible(); window = w
        startInboundPairing(); requestAndPromptForRunner(); startReverse(localPort: nil, remotePort: 12005); startReverse(localPort: nil, remotePort: 12007); startReverse(localPort: 8100, remotePort: 18100); startReverse(localPort: 9100, remotePort: 19100)
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.healthLabel?.text = RelayHealth.shared.summary() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { vc.starting = false; vc.setNeedsStatusBarAppearanceUpdate() }
        log("normal launch; Swift relay host ready"); return true
    }
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid
    private func requestShortBackgroundLease(_ application: UIApplication) {
        guard backgroundLease == .invalid else { return }
        backgroundLease = application.beginBackgroundTask(withName: "relay-grace-period") { [weak self] in
            guard let self else { return }
            if self.backgroundLease != .invalid {
                application.endBackgroundTask(self.backgroundLease)
                self.backgroundLease = .invalid
            }
        }
        // iOS grants only a bounded grace period; this is not an indefinite background server.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, self.backgroundLease != .invalid else { return }
            application.endBackgroundTask(self.backgroundLease)
            self.backgroundLease = .invalid
        }
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        (window?.rootViewController as? HostController)?.starting = false
        requestShortBackgroundLease(application)
    }
    func applicationWillEnterForeground(_ application: UIApplication) {
        requestAndPromptForRunner()
        if backgroundLease != .invalid {
            application.endBackgroundTask(backgroundLease)
            backgroundLease = .invalid
        }
    }
}


@main
struct VisibleHostMain {
    static func main() {
        _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
    }
}
