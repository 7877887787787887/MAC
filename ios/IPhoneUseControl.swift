import UIKit
import Foundation

final class ControlViewController: UIViewController {
    private let host = UITextField()
    private let port = UITextField()
    private let token = UITextField()
    private let status = UILabel()
    private let preview = UIImageView()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "iPhone Use Control"
        view.backgroundColor = .systemBackground
        host.placeholder = "MSI or Tailscale host"
        port.placeholder = "Port"
        port.text = "8100"
        token.placeholder = "Runner token (optional)"
        token.isSecureTextEntry = true
        [host, port, token].forEach {
            $0.borderStyle = .roundedRect
            $0.autocorrectionType = .no
        }
        status.text = "Not connected"
        status.textColor = .secondaryLabel
        preview.backgroundColor = .secondarySystemBackground
        preview.contentMode = .scaleAspectFit
        preview.layer.cornerRadius = 12
        preview.clipsToBounds = true

        let connect = button("Connect", #selector(connectPressed))
        let start = button("Start runner", #selector(startPressed))
        let reconnect = button("Reconnect", #selector(reconnectPressed))
        let home = button("Home", #selector(homePressed))
        let controls = UIStackView(arrangedSubviews: [start, reconnect, home])
        controls.axis = .horizontal
        controls.spacing = 8
        controls.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [host, port, token, connect, status, preview, controls])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            preview.heightAnchor.constraint(equalToConstant: 300)
        ])
    }

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private var baseURL: URL? {
        guard let h = host.text, !h.isEmpty else { return nil }
        return URL(string: "http://\(h):\(port.text ?? "8100")")
    }

    @objc private func connectPressed() { request("/status") }
    @objc private func startPressed() { request("/start") }
    @objc private func reconnectPressed() { request("/reconnect") }
    @objc private func homePressed() { request("/wda/homescreen") }

    private func request(_ path: String) {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL) else {
            status.text = "Enter a valid host and port"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if let value = token.text, !value.isEmpty {
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let error {
                    self?.status.text = "Offline: \(error.localizedDescription)"
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self?.status.text = "Connected (HTTP \(code))"
                    self?.startPreview()
                }
            }
        }.resume()
    }

    private func startPreview() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let baseURL = self.baseURL,
                  let url = URL(string: "/screenshot", relativeTo: baseURL) else { return }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                DispatchQueue.main.async { self.preview.image = image }
            }.resume()
        }
    }

    deinit { timer?.invalidate() }
}

@UIApplicationMain
final class ControlAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UINavigationController(rootViewController: ControlViewController())
        window?.makeKeyAndVisible()
        return true
    }
}