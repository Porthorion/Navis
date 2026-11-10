import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let networkCostChannelName = "com.navis.app/network_cost"
  private let pathMonitor = NWPathMonitor()
  private let pathMonitorQueue = DispatchQueue(label: "com.navis.app.network_cost")
  private var latestPath: NWPath?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      self?.latestPath = path
    }
    pathMonitor.start(queue: pathMonitorQueue)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    FlutterMethodChannel(
      name: "com.navis.app/storage_capacity",
      binaryMessenger: messenger
    ).setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "freeBytes":
        DispatchQueue.global(qos: .utility).async {
          let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path)
          let bytes = attributes?[.systemFreeSize] as? NSNumber
          DispatchQueue.main.async { result(bytes ?? NSNull()) }
        }
      case "excludeFromBackup":
        // Re-downloadable media must stay out of iCloud and iTunes backups; the
        // flag on a directory covers its contents.
        DispatchQueue.global(qos: .utility).async {
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          let excluded = (try? url.setResourceValues(values)) != nil
          DispatchQueue.main.async { result(excluded) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Same channel and call as Android's `MainActivity.kt`; Dart gates by the
    // Settings › Haptics preferences before it calls.
    FlutterMethodChannel(
      name: "com.navis.app/haptics",
      binaryMessenger: messenger
    ).setMethodCallHandler { call, result in
      guard call.method == "perform" else {
        result(FlutterMethodNotImplemented)
        return
      }
      HapticKinds.play(HapticKinds.spec(for: call.arguments as? String ?? ""))
      result(true)
    }

    FlutterMethodChannel(
      name: networkCostChannelName,
      binaryMessenger: messenger
    ).setMethodCallHandler { [weak self] call, result in
      guard call.method == "isActiveNetworkMetered" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(self?.isActiveNetworkMetered() ?? NSNull())
    }
  }

  private func isActiveNetworkMetered() -> Bool? {
    let path = latestPath ?? pathMonitor.currentPath
    return path.isExpensive || path.isConstrained
  }
}
