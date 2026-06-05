import Flutter
import UIKit
import UserNotifications

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

    // App-icon badge + clearing delivered message notifications. Dart drives
    // the count (from the real unread total) and asks to clear a conversation's
    // delivered notifications when the user reads it.
    let badge = FlutterMethodChannel(
      name: "datenow/badge",
      binaryMessenger: controller.binaryMessenger
    )
    badge.setMethodCallHandler { call, result in
      switch call.method {
      case "setBadge":
        let n = (call.arguments as? Int) ?? 0
        UIApplication.shared.applicationIconBadgeNumber = max(0, n)
        result(nil)
      case "clearConversation":
        let convId = call.arguments as? String
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifs in
          let ids = notifs.filter {
            (($0.request.content.userInfo["conversation_id"] as? String) == convId)
          }.map { $0.request.identifier }
          if !ids.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: ids)
          }
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
