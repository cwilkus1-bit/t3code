import UIKit

// Replays what WorkspaceNativeTabs.ios.tsx / WorkspaceSidebarTabs.ios.tsx do on an iPhone with
// the floating (compact) workspace tabs, around the real T3SidebarTabBarView:
// - props: tabs, selectedTab, selectedColor, appearance, showsCompose, compact
// - host frame: absolute, left 8, bottom 0, height 128, right 12 (+64 while compose is hidden)
// - showsCompose only on the Chats tab
// - a pushed Settings page (Environments) unmounts the footer; going back mounts a new one
// - a tab press reaches JS through onSelectionChange; JS commits props and frame together later

let launchTime = CACurrentMediaTime()
let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
let logURL = documents.appendingPathComponent("harness.log")

func log(_ message: String) {
  let line = String(format: "[%8.3f] ", CACurrentMediaTime() - launchTime) + message + "\n"
  FileHandle.standardError.write(Data(line.utf8))
  if let handle = try? FileHandle(forWritingTo: logURL) {
    handle.seekToEndOfFile()
    handle.write(Data(line.utf8))
    try? handle.close()
  } else {
    try? Data(line.utf8).write(to: logURL)
  }
}

func appendLine(_ name: String, _ text: String) {
  let url = documents.appendingPathComponent(name)
  let line = Data((text + "\n").utf8)
  if let handle = try? FileHandle(forWritingTo: url) {
    handle.seekToEndOfFile()
    handle.write(line)
    try? handle.close()
  } else {
    try? line.write(to: url)
  }
}

func fmt(_ rect: CGRect) -> String {
  String(format: "(%.1f, %.1f, %.1f x %.1f)", rect.minX, rect.minY, rect.width, rect.height)
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let window = UIWindow(windowScene: windowScene)
    window.overrideUserInterfaceStyle = .dark
    window.rootViewController = HarnessViewController()
    window.makeKeyAndVisible()
    self.window = window
  }
}

final class HarnessViewController: UIViewController {
  private let tabs = ["threads", "pullRequests", "usage", "settings"]
  private let titles = ["threads": "Chats", "pullRequests": "PRs", "usage": "Usage", "settings": "Settings"]
  private var selectedTab = "threads"
  private var pagePushed = false
  private var bar: T3SidebarTabBarView?
  private var mounts = 0
  private var newChatTaps = 0
  private var recordedComposeCenter = false
  private var lastComposeState = ""
  private let titleLabel = UILabel()
  private let statusLabel = UILabel()
  private let pageButton = UIButton(type: .system)
  private let list = UIStackView()
  private let jsDelay: TimeInterval = {
    Double(ProcessInfo.processInfo.environment["JS_DELAY"] ?? "") ?? 0.05
  }()

  /** onNewTask: compact && !settingsOpen && selectedTab === "threads" */
  private var showsCompose: Bool { selectedTab == "threads" }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    log("harness start jsDelay=\(jsDelay) iOS \(UIDevice.current.systemVersion)")

    // Rows behind the bar so the glass has something to refract.
    list.axis = .vertical
    list.spacing = 10
    list.translatesAutoresizingMaskIntoConstraints = false
    for index in 1...14 {
      let row = UILabel()
      row.text = "  Thread \(index)"
      row.textColor = .label
      row.backgroundColor = UIColor(hue: CGFloat(index) / 14, saturation: 0.35, brightness: 0.35, alpha: 1)
      row.layer.cornerRadius = 10
      row.clipsToBounds = true
      row.heightAnchor.constraint(equalToConstant: 46).isActive = true
      list.addArrangedSubview(row)
    }
    view.addSubview(list)

    titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(titleLabel)

    statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    statusLabel.numberOfLines = 0
    statusLabel.textColor = .systemYellow
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusLabel)

    var buttonConfiguration = UIButton.Configuration.filled()
    buttonConfiguration.cornerStyle = .large
    buttonConfiguration.buttonSize = .large
    pageButton.configuration = buttonConfiguration
    pageButton.addAction(UIAction { [weak self] _ in self?.pressPageButton() }, for: .touchUpInside)
    pageButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pageButton)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      list.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      pageButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pageButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      pageButton.widthAnchor.constraint(equalToConstant: 240),
    ])

    let displayLink = CADisplayLink(target: self, selector: #selector(tick))
    displayLink.add(to: .main, forMode: .common)
    updateContent()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if bar == nil && !pagePushed { mountBar() }
  }

  /** right: (compact ? 12 : 0) + (reserveComposeSpace && !onNewTask ? 64 : 0) */
  private func hostFrame() -> CGRect {
    let right: CGFloat = 12 + (showsCompose ? 0 : 64)
    return CGRect(x: 8, y: view.bounds.height - 128, width: view.bounds.width - 8 - right, height: 128)
  }

  private func mountBar() {
    mounts += 1
    let bar = T3SidebarTabBarView(appContext: nil)
    bar.onSelectionChange.handler = { [weak self] payload in
      guard let tab = payload["tab"] as? String else { return }
      log("native onSelectionChange \(tab)")
      // The press crosses to JS and back before props and layout change.
      DispatchQueue.main.asyncAfter(deadline: .now() + (self?.jsDelay ?? 0)) { self?.commit(tab) }
    }
    bar.onCompose.handler = { [weak self] _ in
      guard let self else { return }
      newChatTaps += 1
      log("NEW CHAT TAPPED count=\(newChatTaps)")
    }
    bar.tabs = tabs
    bar.selectedTab = selectedTab
    bar.selectedColor = UIColor(red: 0.98, green: 0.45, blue: 0.42, alpha: 1)
    bar.appearance = "dark"
    bar.showsCompose = showsCompose
    bar.compact = true
    bar.frame = hostFrame()
    view.addSubview(bar)
    self.bar = bar
    log("mount #\(mounts) selectedTab=\(selectedTab) showsCompose=\(showsCompose) host=\(fmt(bar.frame))")
    if mounts == 1 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.recordTabCenters() }
    }
  }

  private func unmountBar() {
    bar?.removeFromSuperview()
    bar = nil
    log("unmount footer (page pushed)")
  }

  /** JS commit after a tab press: changed props, then the host's new frame. */
  private func commit(_ tab: String) {
    selectedTab = tab
    updateContent()
    guard let bar else { return }
    if bar.selectedTab != tab { bar.selectedTab = tab }
    if bar.showsCompose != showsCompose { bar.showsCompose = showsCompose }
    bar.frame = hostFrame()
    log("js commit tab=\(tab) showsCompose=\(showsCompose) host=\(fmt(bar.frame))")
  }

  private func pressPageButton() {
    if pagePushed {
      pagePushed = false
      log("back to Settings")
      updateContent()
      mountBar()
    } else {
      pagePushed = true
      log("push Settings > Environments")
      unmountBar()
      updateContent()
    }
  }

  private func updateContent() {
    if pagePushed {
      titleLabel.text = "Environments"
      pageButton.configuration?.title = "‹ Back"
    } else {
      titleLabel.text = titles[selectedTab]
      pageButton.configuration?.title = "Environments ›"
    }
    pageButton.isHidden = !(pagePushed || selectedTab == "settings")
    list.isHidden = pagePushed || selectedTab != "threads"
  }

  private func composeButton() -> UIButton? {
    bar?.subviews.first { $0 is UIButton } as? UIButton
  }

  private func recordTabCenters() {
    guard let bar, let tabBar = bar.subviews.first(where: { $0 is UITabBar }) else { return }
    func controls(_ view: UIView) -> [UIView] {
      view.subviews.filter { !$0.isHidden }.flatMap { $0 is UIControl ? [$0] : controls($0) }
    }
    var frames: [CGRect] = []
    for control in controls(tabBar) {
      let frame = control.convert(control.bounds, to: nil)
      guard abs(frame.width - control.bounds.width) < 1, abs(frame.height - control.bounds.height) < 1 else { continue }
      if !frames.contains(where: { abs($0.midX - frame.midX) < 2 }) { frames.append(frame) }
    }
    frames.sort { $0.minX < $1.minX }
    if frames.count != tabs.count {
      let row = tabBar.convert(tabBar.bounds, to: nil)
      log("tab controls found=\(frames.count); splitting the bar evenly")
      let width = row.width / CGFloat(tabs.count)
      frames = tabs.indices.map { CGRect(x: row.minX + CGFloat($0) * width, y: row.midY, width: width, height: 1) }
    }
    for (tab, frame) in zip(tabs, frames) {
      appendLine("coords.txt", String(format: "%@ %.1f %.1f", tab, frame.midX, frame.midY))
      log("tab \(tab) center=(\(frame.midX), \(frame.midY))")
    }
    let page = pageButton.convert(pageButton.bounds, to: nil)
    appendLine("coords.txt", String(format: "page %.1f %.1f", page.midX, page.midY))
  }

  @objc private func tick() {
    var state = "footer unmounted"
    if let bar, let compose = composeButton() {
      let model = bar.convert(compose.frame, to: nil)
      let presented = compose.layer.presentation().map { bar.convert($0.frame, to: nil) } ?? model
      state = "compose hidden=\(compose.isHidden) frame=\(fmt(model)) onscreen=\(fmt(presented))"
      if !recordedComposeCenter, !compose.isHidden, model.width > 0 {
        recordedComposeCenter = true
        appendLine("coords.txt", String(format: "compose %.1f %.1f", model.midX, model.midY))
      }
    }
    if state != lastComposeState {
      lastComposeState = state
      log(state)
    }
    statusLabel.text = "mounts: \(mounts)  new chat taps: \(newChatTaps)\n" + state
  }
}
