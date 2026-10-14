import Flutter
import UIKit
import UniformTypeIdentifiers

/// The Join screen's paste suggestion (#221). Whether the clipboard
/// probably holds a link is asked without reading it, so iOS shows no
/// notice; the paste itself is Apple's own button (`UIPasteControl`),
/// which iOS trusts without asking "Allow Paste?", as an app-drawn
/// button's read would on every tap.
enum PasteLink {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "com.sharneng.spliit2go/paste_link", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "probablyHasLink" else { return result(FlutterMethodNotImplemented) }
      let pasteboard = UIPasteboard.general
      if pasteboard.hasURLs { return result(true) }
      guard pasteboard.hasStrings else { return result(false) }
      pasteboard.detectPatterns(for: [.probableWebURL]) { found in
        let link = (try? found.get())?.contains(.probableWebURL) ?? false
        DispatchQueue.main.async { result(link) }
      }
    }
    registrar.register(
      PasteButtonFactory(messenger: registrar.messenger()),
      withId: "com.sharneng.spliit2go/paste_button")
  }
}

private class PasteButtonFactory: NSObject, FlutterPlatformViewFactory {
  let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?)
    -> FlutterPlatformView
  {
    let channel = FlutterMethodChannel(
      name: "com.sharneng.spliit2go/paste_button_\(viewId)", binaryMessenger: messenger)
    return PasteButton(frame: frame, channel: channel, colors: args as? [String: Any] ?? [:])
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

/// The control, and the target it pastes into: the text goes to Dart as
/// "pasted".
private class PasteButton: NSObject, FlutterPlatformView {
  private let target: PasteTarget

  init(frame: CGRect, channel: FlutterMethodChannel, colors: [String: Any]) {
    target = PasteTarget(frame: frame)
    super.init()
    target.onPaste = { channel.invokeMethod("pasted", arguments: $0) }

    var config = UIPasteControl.Configuration()
    config.displayMode = .iconOnly
    config.cornerStyle = .capsule
    if let argb = colors["background"] as? Int { config.baseBackgroundColor = UIColor(argb: argb) }
    if let argb = colors["foreground"] as? Int { config.baseForegroundColor = UIColor(argb: argb) }
    let control = UIPasteControl(configuration: config)
    control.target = target
    control.frame = target.bounds
    control.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    target.addSubview(control)
  }

  func view() -> UIView { target }
}

private class PasteTarget: UIView {
  var onPaste: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
      UTType.url.identifier, UTType.plainText.identifier,
    ])
  }

  required init?(coder: NSCoder) { fatalError("not from a storyboard") }

  override func paste(itemProviders: [NSItemProvider]) {
    guard let provider = itemProviders.first else { return }
    let deliver: (String?) -> Void = { text in
      guard let text else { return }
      DispatchQueue.main.async { self.onPaste?(text) }
    }
    if provider.canLoadObject(ofClass: URL.self) {
      _ = provider.loadObject(ofClass: URL.self) { url, _ in deliver(url?.absoluteString) }
    } else if provider.canLoadObject(ofClass: String.self) {
      _ = provider.loadObject(ofClass: String.self) { text, _ in deliver(text) }
    }
  }
}

private extension UIColor {
  convenience init(argb: Int) {
    self.init(
      red: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
      blue: CGFloat(argb & 0xFF) / 255, alpha: CGFloat((argb >> 24) & 0xFF) / 255)
  }
}
