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
