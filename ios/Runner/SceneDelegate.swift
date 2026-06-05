import Flutter
import UIKit

/// Subclasses `FlutterSceneDelegate` so the Flutter view controller is
/// set up by the default machinery, then attaches the `datenow/push_env`
/// MethodChannel that lets Dart query the real `aps-environment`
/// entitlement of the running build (see `AppDelegate.detectApnsEnvironment`).
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)

    guard let controller = window?.rootViewController as? FlutterViewController
    else { return }

    let channel = FlutterMethodChannel(
      name: "datenow/push_env",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "apnsEnvironment":
        result(AppDelegate.detectApnsEnvironment())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Keep the screen awake during a live video date (FaceTime-style). Dart
    // calls enable() when the call surface mounts and disable() when it is
    // torn down, so the idle timer is only ever disabled for the call.
    let wakelock = FlutterMethodChannel(
      name: "datenow/wakelock",
      binaryMessenger: controller.binaryMessenger
    )
    wakelock.setMethodCallHandler { call, result in
      switch call.method {
      case "enable":
        UIApplication.shared.isIdleTimerDisabled = true
        result(nil)
      case "disable":
        UIApplication.shared.isIdleTimerDisabled = false
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
