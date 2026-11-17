import UIKit
import Foundation
import Darwin

private enum RelayConfig {
    static let defaultHosts = ["100.114.29.8", "msi.tail28f016.ts.net", "100.94.142.66"]
    static let pairingPort: UInt16 = 12005
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
        if n <= 0 { return false }; sent += n
    }
    return true
}
private func relay(_ a: Int32, _ b: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65536)
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
        guard count > 0, buffer.withUnsafeBytes({ sendAll(destination, $0.baseAddress!, count) }) else { break }
    }
    close(a); close(b)
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
        while true {
            var worked = false
            for host in hosts() {
                RelayHealth.shared.set("\(remotePort)", "trying \(host)")
                let bridge = dial(host, remotePort); if bridge < 0 { continue }
                worked = true; delay = 1; RelayHealth.shared.set("\(remotePort)", "connected via \(host)"); log("connected to \(host):\(remotePort)")
                let upstream: Int32 = localPort == nil ? (remotePort == RelayConfig.pairingPort ? pairingUpstream() : loopback(62078)) : loopback(localPort!)
                if upstream >= 0 { relay(bridge, upstream) } else { close(bridge); log("local upstream unavailable") }
                break
            }
            if worked { sleep(1) } else { RelayHealth.shared.set("\(remotePort)", "retrying in \(delay)s"); log("no host reachable for \(remotePort); retry in \(delay)s"); sleep(delay); delay = min(delay * 2, 8) }
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
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let vc = HostController(); vc.view.backgroundColor = UIColor(red: 0.035, green: 0.047, blue: 0.071, alpha: 1)
        let title = UILabel(); title.translatesAutoresizingMaskIntoConstraints = false; title.text = "Connecting to Windows"; title.textColor = .white; title.font = .boldSystemFont(ofSize: 28); title.textAlignment = .center
        let status = UILabel(); status.translatesAutoresizingMaskIntoConstraints = false; status.text = "Control, video, and secure-pairing relays are connecting to the Windows host. Keep this screen open while secure pairing completes."; status.textColor = UIColor(white: 0.82, alpha: 1); status.font = .systemFont(ofSize: 17); status.numberOfLines = 0; status.textAlignment = .center
        vc.view.addSubview(title); vc.view.addSubview(status)
        healthLabel = status
        NSLayoutConstraint.activate([title.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor), title.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor, constant: -50), status.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24), status.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 28), status.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -28)])
        let w = UIWindow(frame: UIScreen.main.bounds); w.rootViewController = vc; w.makeKeyAndVisible(); window = w
        startInboundPairing(); startReverse(localPort: nil, remotePort: 12005); startReverse(localPort: nil, remotePort: 12007); startReverse(localPort: 8100, remotePort: 18100); startReverse(localPort: 9100, remotePort: 19100)
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.healthLabel?.text = RelayHealth.shared.summary() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { vc.starting = false; vc.setNeedsStatusBarAppearanceUpdate() }
        log("normal launch; Swift relay host ready"); return true
    }
    func applicationDidEnterBackground(_ application: UIApplication) { (window?.rootViewController as? HostController)?.starting = false }
}


@main
struct VisibleHostMain {
    static func main() {
        _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
    }
}
