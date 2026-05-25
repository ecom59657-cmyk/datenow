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
  }
}
