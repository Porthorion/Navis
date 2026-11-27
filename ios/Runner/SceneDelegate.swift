import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  // Siri's `.continueInApp` hands the `INPlayMediaIntent` over as a user
  // activity, at launch or while the scene is alive.
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    for activity in connectionOptions.userActivities {
      SiriBridge.shared.takeUserActivity(activity)
    }
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
    SiriBridge.shared.takeUserActivity(userActivity)
  }
}
