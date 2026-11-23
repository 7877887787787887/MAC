import UIKit
import Foundation

final class ControlModel {
    var host = UserDefaults.standard.string(forKey: "host") ?? ""
    var port = UserDefaults.standard.string(forKey: "port") ?? "8100"
    var token = UserDefaults.standard.string(forKey: "token") ?? ""
    func save() { UserDefaults.standard.set(host, forKey:"host"); UserDefaults.standard.set(port, forKey:"port"); UserDefaults.standard.set(token, forKey:"token") }
    func url(_ path: String) -> URL? { URL(string: "http://\(host):\(port)\(path)") }
}
final class ControlViewController: UIViewController {
    let model = ControlModel(), hostField=UITextField(), portField=UITextField(), tokenField=UITextField(), status=UILabel(), preview=UIImageView(), connect=UIButton(type:.system)
    var timer: Timer?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground; title="iPhone Use Control"
        hostField.placeholder="MSI/Tailscale host"; hostField.text=model.host; portField.placeholder="Port"; portField.text=model.port; portField.keyboardType=.numberPad; tokenField.placeholder="Runner token (optional)"; tokenField.text=model.token; tokenField.isSecureTextEntry=true
        [hostField,portField,tokenField].forEach{$0.borderStyle=.roundedRect;$0.autocorrectionType=.no}; status.text="Not connected"; status.textColor=.secondaryLabel
        preview.contentMode=.scaleAspectFit; preview.backgroundColor=.secondarySystemBackground; preview.layer.cornerRadius=12; preview.clipsToBounds=true
        connect.setTitle("Connect",for:.normal); connect.addTarget(self,action:#selector(connectTap),for:.touchUpInside)
        let row=UIStackView(arrangedSubviews:[hostField,portField,tokenField,connect]); row.axis=.vertical; row.spacing=10
        let controls=UIStackView(); controls.axis=.horizontal; controls.distribution=.fillEqually; controls.spacing=8
        for (name,sel) in [("Start runner",#selector(startTap)),("Reconnect",#selector(reconnectTap)),("Home",#selector(homeTap))] { let b=UIButton(type:.system); b.setTitle(name,for:.normal); b.addTarget(self,action:sel,for:.touchUpInside); controls.addArrangedSubview(b) }
        let stack=UIStackView(arrangedSubviews:[row,status,preview,controls]); stack.axis=.vertical; stack.spacing=12; stack.translatesAutoresizingMaskIntoConstraints=false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:16),preview.heightAnchor.constraint(equalToConstant:300)])
    }
    @objc func connectTap(){ model.host=hostField.text ?? ""; model.port=portField.text ?? "8100"; model.token=tokenField.text ?? ""; model.save(); status.text="Connecting…"; request("/status") }
    @objc func startTap(){ request("/start") }; @objc func reconnectTap(){ request("/reconnect") }; @objc func homeTap(){ request("/wda/homescreen") }
    func request(_ path:String){ guard let u=model.url(path) else {status.text="Invalid host or port";return}; var r=URLRequest(url:u); r.timeoutInterval=5; if !model.token.isEmpty {r.setValue("Bearer \(model.token)",forHTTPHeaderField:"Authorization")}; URLSession.shared.dataTask(with:r){[weak self]d,resp,e in DispatchQueue.main.async{if let e{self?.status.text="Offline: \(e.localizedDescription)";return}; self?.status.text="Connected (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))"; self?.pollPreview()}}.resume() }
    func pollPreview(){ timer?.invalidate(); timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self]_ in guard let self,let u=self.model.url("/screenshot") else{return}; var r=URLRequest(url:u); r.timeoutInterval=3; if !self.model.token.isEmpty{r.setValue("Bearer \(self.model.token)",forHTTPHeaderField:"Authorization")}; URLSession.shared.dataTask(with:r){d,_,_ in if let d,let image=UIImage(data:d){DispatchQueue.main.async{self.preview.image=image}}}.resume()}}
    deinit{timer?.invalidate()}
}
@UIApplicationMain final class ControlAppDelegate:UIResponder,UIApplicationDelegate{
    var window:UIWindow?
    func application(_ app:UIApplication,didFinishLaunchingWithOptions opts:[UIApplication.LaunchOptionsKey:Any]?=nil)->Bool{window=UIWindow(frame:UIScreen.main.bounds);window?.rootViewController=UINavigationController(rootViewController:ControlViewController());window?.makeKeyAndVisible();return true}
}