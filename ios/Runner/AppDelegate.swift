import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Reads the `aps-environment` entitlement baked into the app's
  /// `embedded.mobileprovision` at code-sign time. This is the only
  /// authoritative source for the APNs environment the current build
  /// targets — `kReleaseMode` and the value typed into
  /// `Runner.entitlements` can both lie (Xcode merges the entitlement
  /// file with the active provisioning profile at sign time).
  ///
  /// Returns:
  ///   "development" — debug builds + ad-hoc / dev distribution
  ///   "production"  — TestFlight + App Store + Enterprise distribution
  ///                    (App Store builds ship without
  ///                    embedded.mobileprovision, so we assume prod)
  ///   "development" — iOS simulator (never receives real pushes anyway)
  static func detectApnsEnvironment() -> String {
    #if targetEnvironment(simulator)
    return "development"
    #else
    guard let url = Bundle.main.url(
            forResource: "embedded", withExtension: "mobileprovision"
          ),
          let data = try? Data(contentsOf: url),
          let raw = String(data: data, encoding: .ascii) else {
      // App Store builds strip the provisioning profile out of the IPA.
      return "production"
    }
    // The .mobileprovision is a CMS-signed plist. The relevant excerpt:
    //   <key>aps-environment</key>
    //   <string>development</string>   (or <string>production</string>)
    if let keyRange = raw.range(of: "aps-environment") {
      let tail = raw[keyRange.upperBound...]
      if let openTag = tail.range(of: "<string>") {
        let afterOpen = tail[openTag.upperBound...]
        if let closeTag = afterOpen.range(of: "</string>") {
          let value = afterOpen[..<closeTag.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if value == "development" || value == "production" {
            return value
          }
        }
      }
    }
    return "production"
    #endif
  }
}
