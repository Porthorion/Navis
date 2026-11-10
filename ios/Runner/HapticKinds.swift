import UIKit

/// One native feedback: an impact (style and strength), the selection tick or
/// a success/warning/error notification.
enum HapticSpec: Equatable {
  case impact(UIImpactFeedbackGenerator.FeedbackStyle, CGFloat)
  case selection
  case notification(UINotificationFeedbackGenerator.FeedbackType)
}

/// Maps the haptic vocabulary in `navis_haptics.dart` to the closest iOS
/// analogue of the Android constant in `HapticKinds.kt`.
enum HapticKinds {
  static func spec(for kind: String) -> HapticSpec {
    switch kind {
    case "toggleOn": return .impact(.rigid, 0.6)
    case "toggleOff": return .impact(.soft, 0.5)
    case "press": return .impact(.light, 0.8)
    case "release": return .impact(.soft, 0.35)
    case "firm": return .impact(.medium, 0.8)
    case "tick": return .selection
    case "frequentTick": return .impact(.light, 0.3)
    case "contextClick": return .impact(.rigid, 0.4)
    case "confirm": return .notification(.success)
    case "reject": return .notification(.error)
    case "thresholdOn": return .impact(.rigid, 0.9)
    case "thresholdOff": return .impact(.soft, 0.8)
    case "dragStart": return .impact(.medium, 1)
    case "dragEnd": return .impact(.light, 0.6)
    case "longPress": return .impact(.heavy, 1)
    default: return .impact(.light, 1)
    }
  }

  /// Plays [spec]; call on the main thread.
  static func play(_ spec: HapticSpec) {
    switch spec {
    case let .impact(style, intensity):
      UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
    case .selection:
      UISelectionFeedbackGenerator().selectionChanged()
    case let .notification(type):
      UINotificationFeedbackGenerator().notificationOccurred(type)
    }
  }
}
