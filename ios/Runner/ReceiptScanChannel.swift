import AVFoundation
import Flutter
import UIKit
import Vision
import VisionKit

/// Receipt scanning on the iPhone (#155), for lib/services/receipt_scanner.dart:
/// the same channel and answers as Android's ReceiptScanChannel.kt, so the
/// Dart side is shared. Apple's frameworks rather than ML Kit, which on iOS
/// would bring CocoaPods into the SwiftPM-only build (#105). Both are part
/// of iOS: nothing to download, so there's no prepareScanner or text model
/// call here (the Dart side doesn't make them on iOS).
///
/// - scanDocument: VisionKit's document camera; the first page as JPEG, or
///   nil when cancelled. image_picker's camera_access_denied or _restricted
///   when camera access is refused, without opening it. "unavailable"
///   where it can't run or fails otherwise, and the app uses the plain
///   camera instead. It can't import a photo, so the
///   app asks camera or library first.
/// - recognizeText: every line of text Vision reads, with its box and
///   corners in the image's pixels, top-left origin, as ML Kit gives them.
///   iOS 16's Vision reads Chinese and Japanese as well as Latin languages.
final class ReceiptScanChannel: NSObject, VNDocumentCameraViewControllerDelegate {
  static let name = "com.sharneng.spliit2go/receipt_scan"

  private var pendingScan: FlutterResult?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ReceiptScanChannel()
    let channel = FlutterMethodChannel(name: name, binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in instance.handle(call, result: result) }
    // The channel holds the handler, which holds the instance.
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "scanDocument":
      scanDocument(result)
    case "recognizeText":
      guard let jpeg = args?["jpeg"] as? FlutterStandardTypedData else {
        return result(FlutterError(code: "decode", message: "No image", details: nil))
      }
      recognizeText(jpeg.data, script: args?["script"] as? String ?? "latin", result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Document camera

  private func scanDocument(_ result: @escaping FlutterResult) {
    // One scanner at a time: a second tap while one is open is ignored.
    if pendingScan != nil { return result(nil) }
    guard VNDocumentCameraViewController.isSupported else {
      return result(FlutterError(code: "unavailable", message: "No document camera on this device", details: nil))
    }
    // Camera access refused: the document camera would open only to say
    // so in its own alert and then sit on a black screen until cancelled.
    // image_picker's code instead, so the app explains it with a way to
    // Settings, as it does for the plain camera.
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .denied:
      return result(FlutterError(code: "camera_access_denied", message: "Camera access is off", details: nil))
    case .restricted:
      return result(FlutterError(code: "camera_access_restricted", message: "Camera access is restricted", details: nil))
    default:
      break
    }
    guard let presenter = Self.topViewController() else {
      return result(FlutterError(code: "unavailable", message: "Nothing to present the camera from", details: nil))
    }
    pendingScan = result
    let camera = VNDocumentCameraViewController()
    camera.delegate = self
    presenter.present(camera, animated: true)
  }

  private static func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func finish(_ controller: VNDocumentCameraViewController, _ answer: Any?) {
    let result = pendingScan
    pendingScan = nil
    controller.dismiss(animated: true) { result?(answer) }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
  ) {
    // A receipt is one page; the camera allows more, and the rest are left.
    guard scan.pageCount > 0, let jpeg = scan.imageOfPage(at: 0).jpegData(compressionQuality: 0.9) else {
      return finish(controller, nil)
    }
    finish(controller, FlutterStandardTypedData(bytes: jpeg))
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    finish(controller, nil)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFailWithError error: Error
  ) {
    // Camera access refused while it was open (asked for the first time
    // and declined): the document camera has already said so. The plain
    // camera would only be refused too, so it's a cancel.
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .denied, .restricted:
      finish(controller, nil)
    default:
      finish(controller, FlutterError(code: "unavailable", message: error.localizedDescription, details: nil))
    }
  }

  // MARK: Text

  /// The languages Vision reads for a receipt language (#153), the picked
  /// one first. Each also reads English, as ML Kit's models read Latin.
  private static func languages(_ script: String) -> [String] {
    switch script {
    case "chinese": return ["zh-Hans", "zh-Hant", "en-US"]
    case "japanese": return ["ja-JP", "en-US"]
    default: return ["en-US", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR"]
    }
  }

  private func recognizeText(_ jpeg: Data, script: String, result: @escaping FlutterResult) {
    guard let image = UIImage(data: jpeg), let cgImage = Self.upright(image) else {
      return result(FlutterError(code: "decode", message: "Not an image", details: nil))
    }
    let width = cgImage.width, height = cgImage.height
    let request = VNRecognizeTextRequest { request, error in
      if let error {
        return DispatchQueue.main.async {
          result(FlutterError(code: "recognize", message: error.localizedDescription, details: nil))
        }
      }
      let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap {
        Self.line($0, width: width, height: height)
      }
      DispatchQueue.main.async {
        result(["width": width, "height": height, "lines": lines])
      }
    }
    request.recognitionLevel = .accurate
    request.recognitionLanguages = Self.languages(script)
    // Language correction joins split words, but also "corrects" prices
    // and codes; spliit-ios leaves it on, as Vision's default.
    request.usesLanguageCorrection = true
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "recognize", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  /// [image] drawn upright, so the boxes and the size reported match the
  /// pixels as the photo is shown.
  private static func upright(_ image: UIImage) -> CGImage? {
    if image.imageOrientation == .up { return image.cgImage }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }.cgImage
  }

  /// One line as ML Kit's bridge answers it: pixels, top-left origin, and
  /// its corners clockwise from its top left. Vision's are normalized, from
  /// the bottom left. Unlike ML Kit, Vision gives a short line (a price) on
  /// a tilted page as an upright box, its tilt unknown; the character-range
  /// boxes are no different.
  private static func line(_ o: VNRecognizedTextObservation, width: Int, height: Int) -> [String: Any]? {
    guard let text = o.topCandidates(1).first?.string, !text.isEmpty else { return nil }
    let w = Double(width), h = Double(height)
    func px(_ p: CGPoint) -> [Int] { [Int((p.x * w).rounded()), Int(((1 - p.y) * h).rounded())] }
    let box = o.boundingBox
    return [
      "text": text,
      "left": Int((box.minX * w).rounded()),
      "top": Int(((1 - box.maxY) * h).rounded()),
      "right": Int((box.maxX * w).rounded()),
      "bottom": Int(((1 - box.minY) * h).rounded()),
      "corners": px(o.topLeft) + px(o.topRight) + px(o.bottomRight) + px(o.bottomLeft),
    ]
  }
}
