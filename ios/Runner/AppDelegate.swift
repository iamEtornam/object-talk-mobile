import CoreImage
import Flutter
import UIKit
import Vision

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
    SubjectLift.register(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// Lifts the scanned object out of the frame with Vision's foreground
/// instance mask (the system "lift subject" tech, as in the Swift app's
/// `SubjectCutout`). Returns a full-size PNG with everything but the subject
/// transparent, or nil when no subject is found.
enum SubjectLift {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "object_talk/subject", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "lift",
            let args = call.arguments as? [String: Any],
            let image = (args["image"] as? FlutterStandardTypedData)?.data
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      let box = args["box"] as? [Double]
      DispatchQueue.global(qos: .userInitiated).async {
        let png = lift(image, box: box)
        DispatchQueue.main.async { result(png.map { FlutterStandardTypedData(bytes: $0) }) }
      }
    }
  }

  /// [box] is [top, left, bottom, right], normalised with y from the top.
  static func lift(_ image: Data, box: [Double]?) -> Data? {
    guard #available(iOS 17.0, *) else { return nil }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(data: image)
    do {
      try handler.perform([request])
      guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
      var instances = observation.allInstances
      if let box, box.count == 4 {
        let picked = pickInstances(in: observation.instanceMask, box: box)
        if !picked.isEmpty { instances = picked }
      }
      let buffer = try observation.generateMaskedImage(
        ofInstances: instances, from: handler, croppedToInstancesExtent: false)
      let masked = CIImage(cvPixelBuffer: buffer)
      return CIContext().pngRepresentation(
        of: masked, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    } catch {
      return nil
    }
  }

  /// Instances covering at least 15% of the middle of [box], so the object
  /// Gemini named is lifted and not the couch it sits on.
  private static func pickInstances(in mask: CVPixelBuffer, box: [Double]) -> IndexSet {
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return [] }
    let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
    let rowBytes = CVPixelBufferGetBytesPerRow(mask)
    let (top, left, bottom, right) = (box[0], box[1], box[2], box[3])
    let y0 = max(0, Int((top + (bottom - top) * 0.2) * Double(height)))
    let y1 = min(height, Int((top + (bottom - top) * 0.8) * Double(height)))
    let x0 = max(0, Int((left + (right - left) * 0.2) * Double(width)))
    let x1 = min(width, Int((left + (right - left) * 0.8) * Double(width)))
    guard y1 > y0, x1 > x0 else { return [] }

    var counts: [Int: Int] = [:]
    for y in y0..<y1 {
      for x in x0..<x1 {
        let label = Int(base[y * rowBytes + x])
        if label != 0 { counts[label, default: 0] += 1 }
      }
    }
    let area = Double((y1 - y0) * (x1 - x0))
    return IndexSet(counts.filter { Double($0.value) >= area * 0.15 }.map(\.key))
  }
}
