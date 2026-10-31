import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var host: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?
    /// Tells this controller's lines apart from an earlier or later one's.
    let instance = String(UUID().uuidString.prefix(4))

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardDiagnostics.controllerLoaded(instance, needsGlobe: needsInputModeSwitchKey, fullAccess: hasFullAccess)
        model = KeyboardModel(controller: self)
        let root = KeyboardRootView(model: model)
        let host = UIHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        let height = view.heightAnchor.constraint(equalToConstant: KeyboardMetrics.height)
        height.priority = .defaultHigh
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        KeyboardDiagnostics.log(L("键盘#\(instance) 出现", "Keyboard #\(instance) appearing"))
        model.appeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        KeyboardDiagnostics.log(L("键盘#\(instance) 消失（\(model.phaseDescription)）", "Keyboard #\(instance) disappeared (\(model.phaseDescription))"))
        model.disappeared()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        KeyboardDiagnostics.memoryWarning(instance)
    }

    deinit {
        SharedLog.add(L("键盘#\(instance) 释放", "Keyboard #\(instance) released"))
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        model.refreshSelection()
        // Copying in the field itself shows up on the next cursor move.
        model.refreshClipboard()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.noteFieldChange()
        model.refreshReturnKey()
        model.refreshSelection()
        model.refreshClipboard()
    }

    // MARK: - Proxy helpers used by the model

    var proxy: UITextDocumentProxy { textDocumentProxy }

    /// Keyboards may open their own app (App Review 4.4.1), but
    /// `UIApplication.shared` is unavailable to extensions, so the
    /// application instance is found through the responder chain.
    func openContainingApp(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, Any?) -> Void
                let implementation = application.method(for: selector)
                let open = unsafeBitCast(implementation, to: OpenURL.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}

enum KeyboardMetrics {
    static let height: CGFloat = 268
}
