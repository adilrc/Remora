internal import AppKit
internal import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  var onShowOnboarding: (() -> Void)?

  private var window: NSWindow?
  private var splitViewController: SettingsSplitViewController?

  func show() {
    if window == nil {
      window = makeWindow()
    }
    guard let window else { return }
    AppActivation.windowWillShow(window)
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    if let window {
      AppActivation.windowWillClose(window)
    }
  }
}

// MARK: - Private functionality

private extension SettingsWindowController {
  func makeWindow() -> NSWindow {
    let panes: [SettingsPane] = [
      GeneralPane(settings: .shared),
      MetricsPane(settings: .shared, onNeedsScreenRecording: { [weak self] in self?.onShowOnboarding?() }),
      AppsPane(settings: .shared),
      PermissionsPane(onShowOnboarding: { [weak self] in self?.onShowOnboarding?() }),
      ConfigurationPane(settings: .shared),
    ]
    let splitViewController = SettingsSplitViewController(panes: panes)
    self.splitViewController = splitViewController

    let window = NSWindow(contentViewController: splitViewController)
    window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    let toolbar = NSToolbar(identifier: "settings")
    toolbar.displayMode = .iconOnly
    toolbar.showsBaselineSeparator = false
    window.toolbar = toolbar
    window.title = "Settings"
    window.subtitle = ""
    window.setContentSize(NSSize(width: 720, height: 540))
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    splitViewController.onPaneChange = { pane in
      window.title = pane.paneTitle
    }
    splitViewController.selectPane(at: 0)
    return window
  }
}

// MARK: - Panes

@MainActor
protocol SettingsPane: NSViewController {
  var paneTitle: String { get }
  var paneSymbolName: String { get }
}

@MainActor
private final class SettingsSplitViewController: NSSplitViewController {
  var onPaneChange: ((SettingsPane) -> Void)?

  private let panes: [SettingsPane]
  private let sidebar: SettingsSidebarViewController
  private let content = NSViewController()

  init(panes: [SettingsPane]) {
    self.panes = panes
    sidebar = SettingsSidebarViewController(panes: panes)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    content.view = NSView()
    content.view.translatesAutoresizingMaskIntoConstraints = false

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 180
    sidebarItem.canCollapse = false
    addSplitViewItem(sidebarItem)

    let contentItem = NSSplitViewItem(viewController: content)
    contentItem.minimumThickness = 520
    addSplitViewItem(contentItem)

    sidebar.onSelect = { [weak self] index in
      self?.selectPane(at: index)
    }
  }

  func selectPane(at index: Int) {
    guard panes.indices.contains(index) else { return }
    _ = view
    let pane = panes[index]
    guard pane.parent !== content else { return }

    for child in content.children {
      child.view.removeFromSuperview()
      child.removeFromParent()
    }
    content.addChild(pane)
    let paneView = pane.view
    paneView.translatesAutoresizingMaskIntoConstraints = false
    content.view.addSubview(paneView)
    NSLayoutConstraint.activate([
      paneView.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
      paneView.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
      paneView.topAnchor.constraint(equalTo: content.view.topAnchor),
      paneView.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
    ])
    sidebar.select(index: index)
    onPaneChange?(pane)
  }
}

@MainActor
private final class SettingsSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  var onSelect: ((Int) -> Void)?

  private let panes: [SettingsPane]
  private let tableView = NSTableView()

  init(panes: [SettingsPane]) {
    self.panes = panes
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func loadView() {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.style = .sourceList
    tableView.rowHeight = 28
    tableView.allowsEmptySelection = false
    tableView.backgroundColor = .clear
    tableView.dataSource = self
    tableView.delegate = self

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.automaticallyAdjustsContentInsets = true
    view = scrollView
  }

  func select(index: Int) {
    guard tableView.selectedRow != index else { return }
    tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    panes.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let pane = panes[row]
    let cell = NSTableCellView()
    let imageView = NSImageView(image: NSImage(systemSymbolName: pane.paneSymbolName, accessibilityDescription: nil) ?? NSImage())
    imageView.symbolConfiguration = .init(pointSize: 14, weight: .medium)
    imageView.contentTintColor = .controlAccentColor
    let label = NSTextField(labelWithString: pane.paneTitle)
    label.font = .systemFont(ofSize: 13)
    label.lineBreakMode = .byTruncatingTail

    let stack = NSStackView(views: [imageView, label])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(stack)
    cell.imageView = imageView
    cell.textField = label
    NSLayoutConstraint.activate([
      imageView.widthAnchor.constraint(equalToConstant: 20),
      stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard tableView.selectedRow >= 0 else { return }
    onSelect?(tableView.selectedRow)
  }
}

// MARK: - General

@MainActor
private final class GeneralPane: NSViewController, SettingsPane {
  let paneTitle = "General"
  let paneSymbolName = "macwindow"

  private let settings: AppSettings
  private let detachedSwitch = NSSwitch()
  private let positionGrid = PositionGridView()
  private let hotkeyRecorder = HotkeyRecorderView()

  init(settings: AppSettings) {
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func loadView() {
    detachedSwitch.target = self
    detachedSwitch.action = #selector(detachedChanged)
    positionGrid.onChange = { [weak self] anchor in
      self?.settings.position = anchor
    }
    hotkeyRecorder.onChange = { [weak self] shortcut in
      self?.settings.toggleShortcut = shortcut
    }

    view = SettingsForm.page([
      SettingsForm.section(title: "Placement", rows: [
        SettingsForm.row(
          title: "Detach from window",
          subtitle: "Keep the HUD at a fixed spot on screen instead of following the frontmost window. "
            + "You can also use the pin button on the HUD.",
          control: detachedSwitch
        ),
        SettingsForm.row(
          title: "Position",
          subtitle: "Where the HUD sits on the frontmost window. Drag the HUD to move it between slots.",
          control: positionGrid
        ),
      ]),
      SettingsForm.section(title: "Shortcut", rows: [
        SettingsForm.row(
          title: "Show or hide the HUD",
          subtitle: "Click the field, then press a key combination. Escape cancels, Delete clears.",
          control: hotkeyRecorder
        ),
      ]),
    ])

    settings.observe(self) { [weak self] _ in
      self?.refresh()
    }
    refresh()
  }

  @objc private func detachedChanged() {
    settings.isDetached = detachedSwitch.state == .on
  }

  private func refresh() {
    detachedSwitch.state = settings.isDetached ? .on : .off
    positionGrid.selection = settings.position
    positionGrid.isEnabled = !settings.isDetached
    hotkeyRecorder.shortcut = settings.toggleShortcut
  }
}

// MARK: - Metrics

@MainActor
private final class MetricsPane: NSViewController, SettingsPane {
  let paneTitle = "Metrics"
  let paneSymbolName = "gauge.with.dots.needle.67percent"

  private let settings: AppSettings
  private let refreshIntervalPopUp = NSPopUpButton()
  private var checkboxes: [HUDMetric: NSButton] = [:]
  private var orangeFields: [HUDMetric: ThresholdField] = [:]
  private var redFields: [HUDMetric: ThresholdField] = [:]

  /// Called when the metric is switched on without the Screen Recording grant; onboarding takes over.
  private let onNeedsScreenRecording: () -> Void

  init(settings: AppSettings, onNeedsScreenRecording: @escaping () -> Void) {
    self.onNeedsScreenRecording = onNeedsScreenRecording
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func loadView() {
    for interval in RefreshInterval.allCases {
      refreshIntervalPopUp.addItem(withTitle: interval.title)
      refreshIntervalPopUp.lastItem?.tag = interval.rawValue
    }
    refreshIntervalPopUp.target = self
    refreshIntervalPopUp.action = #selector(refreshIntervalChanged)

    let rows = HUDMetric.allCases.map(makeRow)
    view = SettingsForm.page([
      SettingsForm.section(title: "Refresh", rows: [
        SettingsForm.row(
          title: "Refresh every",
          subtitle: "How often CPU, Memory and Energy Impact update. CPU and Energy Impact are averaged over "
            + "this window, so longer intervals give steadier numbers.",
          control: refreshIntervalPopUp
        ),
      ]),
      SettingsForm.section(
        title: "Metrics",
        footer: "Right-click the HUD to toggle metrics quickly, and drag a metric within the HUD to reorder it.",
        rows: rows
      ),
    ])

    settings.observe(self) { [weak self] _ in
      self?.refresh()
    }
    refresh()
  }

  private func makeRow(for metric: HUDMetric) -> NSView {
    let checkbox = NSButton(checkboxWithTitle: metric.title, target: self, action: #selector(checkboxChanged(_:)))
    checkbox.tag = HUDMetric.allCases.firstIndex(of: metric) ?? 0
    checkbox.font = .systemFont(ofSize: 13)
    checkboxes[metric] = checkbox

    let width = SettingsForm.contentWidth - 2 - (SettingsForm.rowHorizontalPadding * 2)
    var views: [NSView] = [checkbox, SettingsForm.caption(metric.summary, width: width)]

    let orange = ThresholdField()
    let red = ThresholdField()
    orange.onCommit = { [weak self] value in self?.thresholdChanged(for: metric, orange: value) }
    red.onCommit = { [weak self] value in self?.thresholdChanged(for: metric, red: value) }
    orangeFields[metric] = orange
    redFields[metric] = red

    let unit = metric.thresholdUnit
    let thresholds = NSStackView(views: [
      colorDot(.systemOrange), smallLabel("Orange from"), orange, smallLabel(unit),
      spacer(16),
      colorDot(.systemRed), smallLabel("Red from"), red, smallLabel(unit),
    ])
    thresholds.orientation = .horizontal
    thresholds.alignment = .centerY
    thresholds.spacing = 4
    views.append(thresholds)

    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.setCustomSpacing(8, after: views[1])
    return SettingsForm.row(content: stack)
  }

  private func smallLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    return label
  }

  private func colorDot(_ color: NSColor) -> NSView {
    let dot = NSView()
    dot.wantsLayer = true
    dot.layer?.backgroundColor = color.cgColor
    dot.layer?.cornerRadius = 4
    dot.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),
    ])
    return dot
  }

  private func spacer(_ width: CGFloat) -> NSView {
    let view = NSView()
    view.widthAnchor.constraint(equalToConstant: width).isActive = true
    return view
  }

  @objc private func refreshIntervalChanged() {
    guard let interval = RefreshInterval(rawValue: refreshIntervalPopUp.selectedTag()) else { return }
    settings.refreshInterval = interval
  }

  @objc private func checkboxChanged(_ sender: NSButton) {
    guard HUDMetric.allCases.indices.contains(sender.tag) else { return }
    let isOn = sender.state == .on
    switch HUDMetric.allCases[sender.tag] {
    case .cpu: settings.showsCPU = isOn
    case .memory: settings.showsMemory = isOn
    case .energyImpact: settings.showsEnergyImpact = isOn
    case .twelveHourPower: settings.showsTwelveHourPower = isOn
    case .launchTimer: settings.showsLaunchTimer = isOn
    case .timeToInteractive: settings.showsTimeToInteractive = isOn
    case .visuallyComplete:
      settings.showsVisuallyComplete = isOn
      if isOn, !ScreenRecordingPermission.isGranted {
        onNeedsScreenRecording()
      }
    }
  }

  private func thresholdChanged(for metric: HUDMetric, orange: Double?) {
    let current = settings.thresholds(for: metric)
    settings.setThresholds(MetricThresholds(orange: orange, red: current.red), for: metric)
  }

  private func thresholdChanged(for metric: HUDMetric, red: Double?) {
    let current = settings.thresholds(for: metric)
    settings.setThresholds(MetricThresholds(orange: current.orange, red: red), for: metric)
  }

  private func refresh() {
    checkboxes[.cpu]?.state = settings.showsCPU ? .on : .off
    checkboxes[.memory]?.state = settings.showsMemory ? .on : .off
    checkboxes[.energyImpact]?.state = settings.showsEnergyImpact ? .on : .off
    checkboxes[.twelveHourPower]?.state = settings.showsTwelveHourPower ? .on : .off
    checkboxes[.launchTimer]?.state = settings.showsLaunchTimer ? .on : .off
    checkboxes[.timeToInteractive]?.state = settings.showsTimeToInteractive ? .on : .off
    checkboxes[.visuallyComplete]?.state = settings.showsVisuallyComplete ? .on : .off

    refreshIntervalPopUp.selectItem(withTag: settings.refreshInterval.rawValue)
    for metric in HUDMetric.allCases {
      let thresholds = settings.thresholds(for: metric)
      orangeFields[metric]?.value = thresholds.orange
      redFields[metric]?.value = thresholds.red
    }
  }
}

// MARK: - Apps

@MainActor
private final class AppsPane: NSViewController, SettingsPane, NSTableViewDataSource, NSTableViewDelegate {
  let paneTitle = "Apps"
  let paneSymbolName = "app.badge.checkmark"

  private struct ExcludedApp {
    var bundleIdentifier: String
    var name: String
    var icon: NSImage?
  }

  private let settings: AppSettings
  private let followSwitch = NSSwitch()
  private let tableView = NSTableView()
  private let removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove") ?? NSImage(), target: nil, action: nil)
  private var excludedApps: [ExcludedApp] = []

  init(settings: AppSettings) {
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func loadView() {
    followSwitch.target = self
    followSwitch.action = #selector(followChanged)

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
    tableView.addTableColumn(column)
    tableView.headerView = nil
    tableView.rowHeight = 36
    tableView.style = .plain
    tableView.allowsEmptySelection = true
    tableView.dataSource = self
    tableView.delegate = self

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    let width = SettingsForm.contentWidth - 2 - (SettingsForm.rowHorizontalPadding * 2)
    NSLayoutConstraint.activate([
      scrollView.widthAnchor.constraint(equalToConstant: width),
      scrollView.heightAnchor.constraint(equalToConstant: 180),
    ])

    let addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add") ?? NSImage(), target: self, action: #selector(addApp))
    removeButton.target = self
    removeButton.action = #selector(removeSelectedApp)
    for button in [addButton, removeButton] {
      button.bezelStyle = .smallSquare
      button.imagePosition = .imageOnly
      button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }
    let buttons = NSStackView(views: [addButton, removeButton])
    buttons.orientation = .horizontal
    buttons.spacing = 0

    let list = NSStackView(views: [scrollView, buttons])
    list.orientation = .vertical
    list.alignment = .leading
    list.spacing = 6

    view = SettingsForm.page([
      SettingsForm.section(title: "Attachment", rows: [
        SettingsForm.row(
          title: "Automatically attach to the active window",
          subtitle: "When off, the HUD stays on the app it is showing. Use “Attach to Active Window” in the "
            + "menu bar or the HUD’s context menu to move it to another app.",
          control: followSwitch
        ),
      ]),
      SettingsForm.section(
        title: "Excluded Apps",
        footer: "The HUD stays hidden while one of these apps is active. You can also right-click the HUD "
          + "and choose “Never Show on” the current app.",
        rows: [SettingsForm.row(content: list)]
      ),
    ])

    settings.observe(self) { [weak self] _ in
      self?.refresh()
    }
    refresh()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    excludedApps.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let app = excludedApps[row]
    let iconView = NSImageView(image: app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle))
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 24),
      iconView.heightAnchor.constraint(equalToConstant: 24),
    ])
    let nameLabel = NSTextField(labelWithString: app.name)
    nameLabel.font = .systemFont(ofSize: 13)
    let identifierLabel = NSTextField(labelWithString: app.bundleIdentifier)
    identifierLabel.font = .systemFont(ofSize: 10)
    identifierLabel.textColor = .secondaryLabelColor
    let text = NSStackView(views: [nameLabel, identifierLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 0

    let cell = NSTableCellView()
    let stack = NSStackView(views: [iconView, text])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
      stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
    ])
    return cell
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    removeButton.isEnabled = tableView.selectedRow >= 0
  }

  @objc private func followChanged() {
    settings.followsActiveWindow = followSwitch.state == .on
  }

  @objc private func addApp() {
    let panel = NSOpenPanel()
    panel.title = "Choose an app to exclude"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.applicationBundle]
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    guard let window = view.window else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      let identifiers = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
      MainActor.assumeIsolated {
        guard let self else { return }
        self.settings.excludedBundleIdentifiers.append(contentsOf: identifiers)
      }
    }
  }

  @objc private func removeSelectedApp() {
    let row = tableView.selectedRow
    guard excludedApps.indices.contains(row) else { return }
    settings.excludedBundleIdentifiers.removeAll { $0 == excludedApps[row].bundleIdentifier }
  }

  private func refresh() {
    followSwitch.state = settings.followsActiveWindow ? .on : .off
    excludedApps = settings.excludedBundleIdentifiers.map { identifier in
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
        return ExcludedApp(bundleIdentifier: identifier, name: identifier, icon: nil)
      }
      let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? url.deletingPathExtension().lastPathComponent
      return ExcludedApp(bundleIdentifier: identifier, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
    }
    tableView.reloadData()
    removeButton.isEnabled = tableView.selectedRow >= 0
  }
}

// MARK: - Permissions

@MainActor
private final class PermissionsPane: NSViewController, SettingsPane {
  let paneTitle = "Permissions"
  let paneSymbolName = "lock.shield"

  private let onShowOnboarding: () -> Void
  private let accessibilityStatus = PermissionsPane.makeStatusLabel(values: ["Granted", "Not granted"])
  private let screenRecordingStatus = PermissionsPane.makeStatusLabel(values: ["Granted", "Required", "Optional"])
  private let setUpButton = NSButton(title: "Set Up…", target: nil, action: nil)

  init(onShowOnboarding: @escaping () -> Void) {
    self.onShowOnboarding = onShowOnboarding
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func loadView() {
    let accessibility = AccessibilityPermission.displayName
    setUpButton.target = self
    setUpButton.action = #selector(showOnboarding)
    let openAccessibility = NSButton(title: "Open System Settings…", target: self, action: #selector(openAccessibilitySettings))
    let openScreenRecording = NSButton(
      title: "Open System Settings…",
      target: self,
      action: #selector(openScreenRecordingSettings)
    )

    view = SettingsForm.page([
      SettingsForm.section(title: "Permissions", rows: [
        SettingsForm.row(
          title: accessibility,
          subtitle: "Used to find the frontmost app’s main window so the HUD can attach to it, "
            + "and to measure Time to Interactive.",
          control: controls([accessibilityStatus, setUpButton, openAccessibility])
        ),
        SettingsForm.row(
          title: "Screen Recording",
          subtitle: "Used by Visually Complete to watch the window render after keyboard focus is detected.",
          control: controls([screenRecordingStatus, openScreenRecording])
        ),
      ]),
    ])

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    AppSettings.shared.observe(self) { [weak self] _ in
      self?.refresh()
    }
    refresh()
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    refresh()
  }

  private func controls(_ views: [NSView]) -> NSView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 8
    for view in views {
      (view as? NSButton)?.controlSize = .small
      (view as? NSButton)?.bezelStyle = .rounded
      (view as? NSTextField)?.alignment = .right
      view.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    return stack
  }

  /// Sized for the widest value it can show, so the buttons beside it never move when it changes.
  private static func makeStatusLabel(values: [String]) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.alignment = .right
    let width = values.map { value in
      label.stringValue = value
      return label.intrinsicContentSize.width
    }.max() ?? 0
    label.widthAnchor.constraint(equalToConstant: ceil(width)).isActive = true
    return label
  }

  @objc private func applicationDidBecomeActive() {
    refresh()
  }

  @objc private func showOnboarding() {
    onShowOnboarding()
  }

  @objc private func openAccessibilitySettings() {
    AccessibilityPermission.openSystemSettings()
  }

  @objc private func openScreenRecordingSettings() {
    ScreenRecordingPermission.openSystemSettings()
  }

  private func refresh() {
    let accessibilityGranted = AccessibilityPermission.isGranted
    accessibilityStatus.stringValue = accessibilityGranted ? "Granted" : "Not granted"
    accessibilityStatus.textColor = accessibilityGranted ? .systemGreen : .systemOrange
    setUpButton.isHidden = accessibilityGranted

    let screenRecordingGranted = ScreenRecordingPermission.isGranted
    if screenRecordingGranted {
      screenRecordingStatus.stringValue = "Granted"
      screenRecordingStatus.textColor = .systemGreen
    } else if AppSettings.shared.showsVisuallyComplete {
      screenRecordingStatus.stringValue = "Required"
      screenRecordingStatus.textColor = .systemOrange
    } else {
      screenRecordingStatus.stringValue = "Optional"
      screenRecordingStatus.textColor = .secondaryLabelColor
    }
  }
}

// MARK: - Configuration

@MainActor
private final class ConfigurationPane: NSViewController, SettingsPane {
  let paneTitle = "Configuration File"
  let paneSymbolName = "doc.text"

  private let settings: AppSettings

  init(settings: AppSettings) {
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func loadView() {
    let path = NSTextField(labelWithString: settings.configurationURL.path)
    path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    path.textColor = .secondaryLabelColor
    path.lineBreakMode = .byTruncatingMiddle
    path.isSelectable = true
    path.toolTip = settings.configurationURL.path

    let open = NSButton(title: "Open", target: self, action: #selector(openConfiguration))
    let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealConfiguration))
    let reload = NSButton(title: "Reload", target: self, action: #selector(reloadConfiguration))
    for button in [open, reveal, reload] {
      button.controlSize = .small
      button.bezelStyle = .rounded
    }
    let buttons = NSStackView(views: [open, reveal, reload])
    buttons.orientation = .horizontal
    buttons.spacing = 8

    let width = SettingsForm.contentWidth - 2 - (SettingsForm.rowHorizontalPadding * 2)
    path.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
    let content = NSStackView(views: [path, buttons])
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 8

    view = SettingsForm.page([
      SettingsForm.section(
        title: "Configuration File",
        footer: "Every setting is stored in this plain-text file as key = value lines. Edit it with any editor: "
          + "changes are applied automatically, and Settings writes back to the same file.",
        rows: [SettingsForm.row(content: content)]
      ),
    ])
  }

  @objc private func openConfiguration() {
    NSWorkspace.shared.open(settings.configurationURL)
  }

  @objc private func revealConfiguration() {
    NSWorkspace.shared.activateFileViewerSelecting([settings.configurationURL])
  }

  @objc private func reloadConfiguration() {
    settings.reload()
  }
}
