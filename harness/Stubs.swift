import UIKit

// Minimal stand-ins for the ExpoModulesCore types T3SidebarTabBarView.swift uses, so the
// unmodified file compiles into a plain UIKit app.
final class AppContext {}

class ExpoView: UIView {
  weak var appContext: AppContext?

  required init(appContext: AppContext? = nil) {
    self.appContext = appContext
    super.init(frame: .zero)
  }

  // Same as ExpoFabricView: unavailable, so subclasses need not override it.
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class EventDispatcher {
  var handler: ([String: Any]) -> Void = { _ in }
  init() {}
  func callAsFunction(_ payload: [String: Any] = [:]) { handler(payload) }
}
