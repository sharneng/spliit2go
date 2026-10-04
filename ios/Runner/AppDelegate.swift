import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Receipt scanning (#155): this app's own bridge, not a plugin.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ReceiptScanChannel") {
      ReceiptScanChannel.register(with: registrar)
    }
    // The commit this build is from (#176), from the BuildInfo.plist that
    // ios/scripts/write_build_info.sh writes into the app.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BuildInfo") {
      let channel = FlutterMethodChannel(
        name: "com.sharneng.spliit2go/build_info", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "gitCommit" else { return result(FlutterMethodNotImplemented) }
        let info = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist")
          .flatMap { NSDictionary(contentsOf: $0) }
        result(info?["GitCommit"] as? String ?? "")
      }
    }
  }
}
