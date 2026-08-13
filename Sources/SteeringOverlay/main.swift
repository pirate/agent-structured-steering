import AppKit
import SwiftUI

private let overlayWidth: CGFloat = 500

struct ObserverInfo: Codable, Equatable { let status: String }

struct SurfaceControl: Codable, Equatable, Identifiable {
  let id: String
  var label: String
  let kind: String
  var help: String
  let emoji: String
  var enabled: Bool
  var selected: [String]
  var options: [String]
  var value: Double
  let min: Double
  let max: Double
  let step: Double
  var salience: Int
}

struct SteeringSurface: Codable, Equatable {
  var revision: Int
  let threadId: String
  let sessionTitle: String
  let projectName: String
  let summary: String
  let observer: ObserverInfo
  var controls: [SurfaceControl]
}

struct SteeringEvent: Codable {
  let timestamp: String
  let revision: Int
  let control: SurfaceControl
  let action: String
  let source: String
}

struct ActiveSession: Decodable { let threadId: String }

struct SurfaceSession: Identifiable, Equatable {
  let surface: SteeringSurface
  let directory: URL
  var id: String { surface.threadId }
}

@MainActor
final class SurfaceStore: ObservableObject {
  @Published private(set) var surface: SteeringSurface?
  @Published private(set) var sessions: [SurfaceSession] = []
  var onSurfaceChange: (() -> Void)?

  private let activePath: String
  private var selectedDirectory: URL?
  private var selectedThreadId: String?
  private var lastActiveData: Data?
  private var timer: Timer?

  init(activePath: String) {
    self.activePath = activePath
    reload()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reload() }
    }
  }

  func setEnabled(_ enabled: Bool, for original: SurfaceControl) {
    update(original) {
      $0.enabled = enabled
      $0.salience = 1
    }
  }

  func setSelection(_ selection: String, for original: SurfaceControl) {
    update(original) {
      $0.selected = [selection]
      $0.salience = 1
    }
  }

  func setValue(_ value: Double, for original: SurfaceControl) {
    update(original) {
      let steps = ((value - $0.min) / $0.step).rounded()
      $0.value = min(max($0.min + steps * $0.step, $0.min), $0.max)
      $0.salience = 1
    }
  }

  func updateText(label: String, help: String, for original: SurfaceControl) {
    update(original, action: "edit") {
      $0.label = String(label.prefix(72))
      $0.help = String(help.prefix(160))
      $0.salience = 1
    }
  }

  func addOption(_ option: String, for original: SurfaceControl) {
    let option = String(option.trimmingCharacters(in: .whitespacesAndNewlines).prefix(72))
    guard !option.isEmpty, original.options.contains(option) || original.options.count < 8 else {
      return
    }
    update(original, action: "option") {
      if !$0.options.contains(option) { $0.options.append(option) }
      $0.selected = [option]
      $0.salience = 1
    }
  }

  func togglePinned(for original: SurfaceControl) {
    update(original, action: original.salience == 1 ? "neutral" : "pin") {
      $0.salience = $0.salience == 1 ? 0 : 1
    }
  }

  func delete(_ control: SurfaceControl) {
    guard var updated = surface,
      let index = updated.controls.firstIndex(where: { $0.id == control.id })
    else { return }
    updated.revision += 1
    let removed = updated.controls.remove(at: index)
    commit(updated, event: removed, action: "delete")
  }

  func select(_ threadId: String) {
    selectedThreadId = threadId
    if let session = sessions.first(where: { $0.id == threadId }) {
      apply(session)
    }
  }

  private func reload() {
    if let activeData = FileManager.default.contents(atPath: activePath),
      activeData != lastActiveData,
      let decoded = try? JSONDecoder().decode(ActiveSession.self, from: activeData)
    {
      lastActiveData = activeData
      selectedThreadId = decoded.threadId
    }
    let threads = URL(fileURLWithPath: activePath)
      .deletingLastPathComponent().appendingPathComponent("threads")
    let directories =
      (try? FileManager.default.contentsOfDirectory(
        at: threads, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    let discovered: [SurfaceSession] = directories.compactMap { directory -> SurfaceSession? in
      let state = directory.appendingPathComponent("state.json")
      guard let data = try? Data(contentsOf: state),
        let surface = try? JSONDecoder().decode(SteeringSurface.self, from: data)
      else { return nil }
      return SurfaceSession(
        surface: surface,
        directory: directory
      )
    }.sorted {
      $0.surface.sessionTitle.localizedCaseInsensitiveCompare($1.surface.sessionTitle)
        == .orderedAscending
    }
    if sessions != discovered { sessions = discovered }
    let selected = sessions.first(where: { $0.id == selectedThreadId }) ?? sessions.first
    if let selected { apply(selected) }
  }

  private func apply(_ session: SurfaceSession) {
    selectedDirectory = session.directory
    guard surface != session.surface else { return }
    surface = session.surface
    onSurfaceChange?()
  }

  private func update(
    _ original: SurfaceControl,
    action: String = "value",
    mutate: (inout SurfaceControl) -> Void
  ) {
    guard var updated = surface,
      let index = updated.controls.firstIndex(where: { $0.id == original.id })
    else { return }
    var control = updated.controls[index]
    mutate(&control)
    guard control != updated.controls[index] else { return }
    updated.revision += 1
    updated.controls[index] = control
    commit(updated, event: control, action: action)
  }

  private func commit(_ updated: SteeringSurface, event control: SurfaceControl, action: String) {
    guard let selectedDirectory else { return }
    let event = SteeringEvent(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      revision: updated.revision,
      control: control,
      action: action,
      source: "user"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let stateData = try? encoder.encode(updated), let eventData = try? encoder.encode(event)
    else { return }

    // The state file is canonical; the append-only event stream is only provenance for the observer.
    let stateURL = selectedDirectory.appendingPathComponent("state.json")
    guard (try? stateData.write(to: stateURL, options: .atomic)) != nil else { return }
    surface = updated
    onSurfaceChange?()

    let eventsURL = selectedDirectory.appendingPathComponent("events.jsonl")
    if !FileManager.default.fileExists(atPath: eventsURL.path) {
      FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: eventsURL) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: eventData + Data([0x0A]))
  }
}

struct OverlayView: View {
  @ObservedObject var store: SurfaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      if let surface = store.surface {
        let pinned = surface.controls.filter { $0.salience == 1 }
        let recent = surface.controls.filter { $0.salience == 0 }
        HStack(alignment: .top, spacing: 8) {
          sessionTabs
          Button("×") { NSApplication.shared.terminate(nil) }
            .buttonStyle(DestructiveIconButtonStyle())
            .font(.system(size: 17, weight: .medium))
            .frame(width: 18, height: 22, alignment: .topTrailing)
        }
        header(surface)
        Text(surface.summary)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if surface.controls.isEmpty {
          ProgressView("Reviewing the agent's recent assumptions…")
            .font(.system(size: 11))
        } else {
          Divider()
          ForEach(pinned) { ControlRow(store: store, control: $0) }
          if !pinned.isEmpty && !recent.isEmpty {
            Capsule()
              .fill(.secondary.opacity(0.25))
              .frame(width: 26, height: 2)
              .frame(maxWidth: .infinity)
          }
          ForEach(recent) { ControlRow(store: store, control: $0) }
        }
      } else {
        ProgressView("Waiting for steering controls…")
      }
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 20)
    .padding(.top, 8)
    .frame(width: overlayWidth, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14), lineWidth: 0.5))
  }

  private func header(_ surface: SteeringSurface) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(displayTitle(surface)).font(.system(size: 14, weight: .semibold))
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
      if !surface.projectName.isEmpty {
        Text(surface.projectName)
          .font(.system(size: 9.5, weight: .medium))
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      Spacer()
    }
  }

  private var sessionTabs: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 5) {
          ForEach(store.sessions) { session in
            let selected = session.id == store.surface?.threadId
            Button {
              store.select(session.id)
            } label: {
              VStack(spacing: 3) {
                FocusMarqueeTabTitle(title: displayTitle(session.surface), selected: selected)
                TabStatusBar(
                  color: tabColor(session.id),
                  selected: selected,
                  loading: session.surface.observer.status == "analyzing"
                )
              }
              .padding(.horizontal, 7)
              .padding(.vertical, 4)
              .background(
                .primary.opacity(selected ? 0.14 : 0.025),
                in: RoundedRectangle(cornerRadius: 6)
              )
            }
            .buttonStyle(.plain)
            .id(session.id)
          }
        }
      }
      .onChange(of: store.surface?.threadId) { _, threadId in
        if let threadId { withAnimation { proxy.scrollTo(threadId, anchor: .center) } }
      }
      .onChange(of: store.sessions.count) { _, _ in
        if let threadId = store.surface?.threadId {
          proxy.scrollTo(threadId, anchor: .center)
        }
      }
      .onAppear {
        if let threadId = store.surface?.threadId {
          proxy.scrollTo(threadId, anchor: .center)
        }
      }
    }
  }

  private func tabColor(_ key: String) -> Color {
    let hash = key.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
      ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
    return Color(hue: Double(hash % 360) / 360, saturation: 0.5, brightness: 0.85)
  }

  private func displayTitle(_ surface: SteeringSurface) -> String {
    surface.sessionTitle.components(separatedBy: .newlines).first ?? surface.threadId
  }

}

private struct FocusMarqueeTabTitle: View {
  let title: String
  let selected: Bool

  @State private var offset: CGFloat = 0
  @State private var marqueeing = false

  private let width: CGFloat = 62

  var body: some View {
    ZStack(alignment: .leading) {
      if selected && marqueeing {
        Text(title)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.primary)
          .fixedSize()
          .offset(x: offset)
      } else {
        Text(title)
          .font(.system(size: 9, weight: selected ? .semibold : .regular))
          .foregroundStyle(selected ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(width: width, alignment: .leading)
      }
    }
    .frame(width: width, height: 11, alignment: .leading)
    .clipped()
    .task(id: selected ? title : nil) {
      // Rendering and animation are both gated by selection so recycled tabs cannot retain motion.
      offset = 0
      marqueeing = false
      guard selected else { return }
      let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
      let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
      let distance = max(0, textWidth - width)
      guard distance > 0 else { return }
      do {
        try await Task.sleep(for: .milliseconds(350))
        marqueeing = true
        let duration = min(6, max(1.5, Double(distance / 22)))
        withAnimation(.linear(duration: duration)) { offset = -distance }
        try await Task.sleep(for: .seconds(duration))
        offset = 0
        marqueeing = false
      } catch {}
    }
  }
}

private struct DestructiveIconButtonStyle: ButtonStyle {
  func makeBody(configuration: ButtonStyleConfiguration) -> some View {
    configuration.label
      .foregroundStyle(configuration.isPressed ? Color.red : Color.secondary.opacity(0.5))
  }
}

private struct ActionTooltip: ViewModifier {
  let text: String
  @State private var visible = false

  func body(content: Content) -> some View {
    content
      .onHover { visible = $0 }
      .overlay(alignment: .trailing) {
        if visible {
          Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor).opacity(1), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.24), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.65), radius: 5, y: 2)
            .fixedSize()
            .offset(x: -28)
            .allowsHitTesting(false)
            .zIndex(10)
        }
      }
  }
}

extension View {
  fileprivate func actionTooltip(_ text: String) -> some View {
    modifier(ActionTooltip(text: text))
  }
}

private struct TabStatusBar: View {
  let color: Color
  let selected: Bool
  let loading: Bool

  @State private var highlightOffset: CGFloat = -18

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(color.opacity(selected ? 1 : 0.35))
        if loading {
          Capsule()
            .fill(.white.opacity(0.45))
            .frame(width: 18)
            .offset(x: highlightOffset)
        }
      }
      .clipShape(Capsule())
      .task(id: loading) {
        // Observer activity belongs to its session tab, so switching tabs never hides the signal.
        highlightOffset = -18
        guard loading else { return }
        while !Task.isCancelled {
          withAnimation(.linear(duration: 1.1)) { highlightOffset = geometry.size.width }
          do {
            try await Task.sleep(for: .seconds(1.25))
          } catch {
            return
          }
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { highlightOffset = -18 }
          do {
            try await Task.sleep(for: .milliseconds(250))
          } catch {
            return
          }
        }
      }
    }
    .frame(height: selected ? 3 : 2)
  }
}

struct ControlRow: View {
  private enum EditMode {
    case idle
    case text
    case option
  }

  private enum FocusedField {
    case title
    case help
    case option
  }

  @ObservedObject var store: SurfaceStore
  let control: SurfaceControl

  @State private var editMode = EditMode.idle
  @State private var hovered = false
  @State private var draftLabel = ""
  @State private var draftHelp = ""
  @State private var draftOption = ""
  @FocusState private var focusedField: FocusedField?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(control.emoji).font(.system(size: 17)).frame(width: 24)
      VStack(alignment: .leading, spacing: 8) {
        if editMode == .text {
          TextField("Title", text: $draftLabel)
            .font(.system(size: 12, weight: .medium))
            .focused($focusedField, equals: .title)
            .onSubmit(commitText)
            .onExitCommand(perform: cancelInput)
          TextField("Description", text: $draftHelp, axis: .vertical)
            .font(.system(size: 11.5))
            .lineLimit(1...3)
            .focused($focusedField, equals: .help)
            .onSubmit(commitText)
            .onExitCommand(perform: cancelInput)
        } else {
          Text(control.label)
            .font(.system(size: 12, weight: control.salience == 1 ? .bold : .medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture(perform: beginEditing)
          if control.kind == "toggle" {
            HStack(alignment: .top, spacing: 12) {
              subtitle
                .frame(maxWidth: .infinity, alignment: .leading)
              editor.fixedSize()
            }
          } else {
            subtitle
            editor.frame(
              maxWidth: .infinity,
              alignment: control.kind == "choice" ? .leading : .trailing
            )
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
      actionIcons
    }
    .padding(.vertical, 2)
    .onHover { hovered = $0 }
  }

  private var subtitle: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(control.help)
        .font(.system(size: 11.5))
        .foregroundStyle(Color.primary.opacity(0.35))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture(perform: beginEditing)
      Button(action: beginEditing) {
        Image(systemName: "pencil")
          .font(.system(size: 8, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .opacity(hovered ? 0.65 : 0)
      .allowsHitTesting(hovered)
      .actionTooltip("Edit")
    }
  }

  private var actionIcons: some View {
    VStack(spacing: 3) {
      if editMode == .idle {
        Button {
          store.togglePinned(for: control)
        } label: {
          Image(systemName: control.salience == 1 ? "pin.fill" : "checkmark")
            .foregroundStyle(control.salience == 1 ? Color.yellow : Color.secondary.opacity(0.4))
        }
        .actionTooltip(control.salience == 1 ? "Unpin" : "Mark correct & pin")
        .opacity(control.salience == 1 || hovered ? 1 : 0)
        .allowsHitTesting(control.salience == 1 || hovered)
        Button {
          store.delete(control)
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(DestructiveIconButtonStyle())
        .actionTooltip("Forget / remove")
        .opacity(hovered ? 1 : 0)
        .allowsHitTesting(hovered)
      } else {
        Button(action: commitInput) {
          Image(systemName: "checkmark").foregroundStyle(Color.green)
        }
        .actionTooltip("Save changes")
        Button(action: cancelInput) {
          Image(systemName: "xmark").foregroundStyle(Color.secondary)
        }
        .actionTooltip("Discard edits")
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 14, weight: .semibold))
    .frame(width: 20, alignment: .trailing)
    .fixedSize(horizontal: true, vertical: false)
  }

  @ViewBuilder private var editor: some View {
    switch control.kind {
    case "toggle":
      VStack(spacing: 1) {
        Text(control.enabled ? "YES" : "NO")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(control.enabled ? Color.green : Color.red)
        Toggle(
          "",
          isOn: Binding(
            get: { control.enabled },
            set: { store.setEnabled($0, for: control) }
          )
        )
        .labelsHidden()
        .toggleStyle(.switch)
      }
      .offset(y: -13)
    case "choice":
      if editMode == .option {
        TextField("Add an option", text: $draftOption)
          .font(.system(size: 10.5))
          .focused($focusedField, equals: .option)
          .onSubmit(commitOption)
          .onExitCommand(perform: cancelInput)
      } else {
        HStack(spacing: 5) {
          if control.options.count <= 3
            && control.options.reduce(0, { $0 + $1.count }) <= 36
          {
            choicePicker.pickerStyle(.segmented)
          } else {
            choicePicker.pickerStyle(.menu)
          }
          Button(action: beginAddingOption) {
            Image(systemName: "plus")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .opacity(hovered ? 0.65 : 0)
          .allowsHitTesting(hovered)
          .actionTooltip("Add a new option")
        }
      }
    case "slider":
      VStack(alignment: .trailing, spacing: 1) {
        Text(
          control.value.rounded() == control.value
            ? String(Int(control.value)) : String(format: "%.1f", control.value)
        )
        .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(
          .secondary)
        Slider(
          value: Binding(
            get: { control.value },
            set: { store.setValue($0, for: control) }
          ), in: control.min...control.max, step: control.step
        ).frame(width: 110)
      }
    default:
      Text(control.selected.first ?? "Active").font(.system(size: 11, weight: .medium))
    }
  }

  private var choicePicker: some View {
    Picker(
      "",
      selection: Binding(
        get: { control.selected.first ?? "" },
        set: { store.setSelection($0, for: control) }
      )
    ) {
      ForEach(control.options, id: \.self) { Text($0).tag($0) }
    }
    .labelsHidden().controlSize(.small)
  }

  private func beginEditing() {
    draftLabel = control.label
    draftHelp = control.help
    editMode = .text
    focusedField = .title
  }

  private func commitText() {
    store.updateText(label: draftLabel, help: draftHelp, for: control)
    editMode = .idle
    focusedField = nil
  }

  private func beginAddingOption() {
    draftOption = ""
    editMode = .option
    focusedField = .option
  }

  private func commitOption() {
    store.addOption(draftOption, for: control)
    editMode = .idle
    focusedField = nil
  }

  private func commitInput() {
    switch editMode {
    case .idle:
      break
    case .text:
      commitText()
    case .option:
      commitOption()
    }
  }

  private func cancelInput() {
    editMode = .idle
    focusedField = nil
  }

}

private final class SteeringPanel: NSPanel {
  // Keep the coding app active while still allowing direct edits inside the panel.
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let activePath: String
  private let resourcePath: String
  private var observer: Process?
  private var panel: NSPanel?
  private var store: SurfaceStore?
  private var keyMonitor: Any?

  init(activePath: String, resourcePath: String) {
    self.activePath = activePath
    self.resourcePath = resourcePath
  }

  func applicationDidFinishLaunching(_: Notification) {
    guard updateHooks("--install-hooks") else {
      NSApplication.shared.terminate(nil)
      return
    }
    startObserver()
    let store = SurfaceStore(activePath: activePath)
    let panel = SteeringPanel(
      contentRect: NSRect(x: 0, y: 0, width: overlayWidth, height: 300),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    let contentView = NSHostingView(rootView: OverlayView(store: store))
    panel.contentView = contentView
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.delegate = self
    let resizePanel = { [weak panel, weak contentView] in
      // Published state arrives before SwiftUI lays out, so measure on the next run loop.
      DispatchQueue.main.async {
        guard let panel, let contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? 720) - 36
        let height = min(max(contentView.fittingSize.height, 120), availableHeight)
        panel.setContentSize(NSSize(width: overlayWidth, height: height))
      }
    }
    store.onSurfaceChange = resizePanel
    Self.anchor(panel, to: NSScreen.screens.first)
    panel.orderFrontRegardless()
    resizePanel()
    self.store = store
    self.panel = panel
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak panel] event in
      if panel?.isKeyWindow == true,
        event.modifierFlags.contains(.command),
        event.charactersIgnoringModifiers == "q"
      {
        NSApplication.shared.terminate(nil)
        return nil
      }
      return event
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

  func applicationWillTerminate(_: Notification) {
    observer?.terminate()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    _ = updateHooks("--uninstall-hooks")
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    panel?.orderFrontRegardless()
    return true
  }

  private func updateHooks(_ action: String) -> Bool {
    let process = makeObserverProcess(arguments: [action])
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  private func startObserver() {
    let process = makeObserverProcess(arguments: [])
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    observer = process
  }

  private func makeObserverProcess(arguments: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "\(resourcePath)/observer.py"] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] =
      "/opt/homebrew/bin:/usr/local/bin:\(environment["HOME"] ?? "")/.local/bin:/usr/bin:/bin"
    process.environment = environment
    return process
  }

  func windowDidResize(_ notification: Notification) {
    guard let panel = notification.object as? NSPanel else { return }
    Self.anchor(panel, to: panel.screen)
  }

  private static func anchor(_ panel: NSPanel, to screen: NSScreen?) {
    guard let screen else { return }
    panel.setFrameOrigin(
      NSPoint(
        x: screen.visibleFrame.maxX - panel.frame.width - 18,
        y: screen.visibleFrame.minY + 18
      ))
  }
}

let activePath = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Structured Steering/active.json").path
let arguments = CommandLine.arguments
let resourcePath =
  arguments.firstIndex(of: "--resource-path").map { arguments[$0 + 1] }
  ?? Bundle.main.resourcePath!
let application = NSApplication.shared
let delegate = AppDelegate(activePath: activePath, resourcePath: resourcePath)
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
