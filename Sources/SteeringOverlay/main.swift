import AppKit
import SwiftUI

private let overlayWidth: CGFloat = 500

@MainActor
final class SurfaceStore: ObservableObject {
  @Published private(set) var surface: SteeringSurface?
  @Published private(set) var toast = ""
  var onSurfaceChange: ((SteeringSurface) -> Void)?

  private let configuration: Configuration
  private var activeSession: ActiveSession?
  private var lastActiveData: Data?
  private var lastStateData: Data?
  private var timer: Timer?

  init(configuration: Configuration) {
    self.configuration = configuration
    reload()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.reload() }
    }
  }

  func effective(_ control: SurfaceControl) -> SurfaceControl {
    control
  }

  func setEnabled(_ enabled: Bool, for original: SurfaceControl) {
    var control = effective(original)
    control.enabled = enabled
    save(control)
  }

  func setSelection(_ selection: String, for original: SurfaceControl) {
    var control = effective(original)
    control.selected = [selection]
    save(control)
  }

  func setValue(_ value: Double, for original: SurfaceControl) {
    var control = effective(original)
    let steps = ((value - control.min) / control.step).rounded()
    control.value = min(max(control.min + steps * control.step, control.min), control.max)
    save(control)
  }

  func copy(_ original: SurfaceControl) {
    record(effective(original))
  }

  private func reload() {
    if let activeData = FileManager.default.contents(atPath: configuration.activePath),
      activeData != lastActiveData,
      let decoded = try? JSONDecoder().decode(ActiveSession.self, from: activeData)
    {
      lastActiveData = activeData
      activeSession = decoded
      lastStateData = nil
    }
    guard let activeSession,
      let data = FileManager.default.contents(atPath: activeSession.statePath),
      data != lastStateData,
      let decoded = try? JSONDecoder().decode(SteeringSurface.self, from: data)
    else { return }
    lastStateData = data
    surface = decoded
    toast = decoded.observer.message
    onSurfaceChange?(decoded)
  }

  private func save(_ control: SurfaceControl) {
    guard var updated = surface,
      let index = updated.controls.firstIndex(where: { $0.id == control.id })
    else { return }
    updated.revision += 1
    updated.controls[index] = control
    surface = updated
    persist(updated)
    record(control)
  }

  private func persist(_ surface: SteeringSurface) {
    guard let activeSession, let data = try? JSONEncoder().encode(surface) else { return }
    try? data.write(to: URL(fileURLWithPath: activeSession.statePath), options: .atomic)
    lastStateData = data
  }

  private func record(_ control: SurfaceControl) {
    guard let surface else { return }
    let event = SteeringEvent(
      timestamp: ISO8601DateFormatter().string(from: Date()),
      revision: surface.revision,
      controlId: control.id,
      label: control.label,
      enabled: control.enabled,
      selected: control.selected,
      value: control.value,
      source: "user"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(event) else { return }
    append(data)
    toast = "Steering state updated"
  }

  private func append(_ data: Data) {
    guard let activeSession else { return }
    let url = URL(fileURLWithPath: activeSession.eventsPath)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data + Data([0x0A]))
  }
}

struct OverlayView: View {
  @ObservedObject var store: SurfaceStore

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      if let surface = store.surface {
        header(surface)
        Text(surface.summary)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(2)
        if surface.controls.isEmpty {
          ProgressView("Reviewing the agent's recent assumptions…")
            .font(.system(size: 11))
        } else {
          Divider()
          ForEach(Array(surface.controls.enumerated()), id: \.element.id) { index, control in
            if index == min(surface.activeCount ?? surface.controls.count, surface.controls.count) {
              if index > 0 { Divider() }
              Text("Recent assumptions")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            ControlRow(store: store, control: store.effective(control))
          }
        }
        Text(store.toast)
          .font(.system(size: 9.5))
          .foregroundStyle(store.toast.hasPrefix("Steering") ? Color.green : Color.secondary)
          .lineLimit(1)
      } else {
        ProgressView("Waiting for steering controls…")
      }
    }
    .padding(20)
    .frame(width: overlayWidth, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14), lineWidth: 0.5))
  }

  private func header(_ surface: SteeringSurface) -> some View {
    HStack(spacing: 8) {
      Circle().fill(statusColor(surface.observer.status)).frame(width: 8, height: 8)
      Text(surface.sessionTitle ?? surface.threadId).font(.system(size: 14, weight: .semibold))
        .lineLimit(1)
      Spacer()
      Button("×") { NSApplication.shared.terminate(nil) }
        .buttonStyle(.plain).font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
    }
  }

  private func statusColor(_ status: String) -> Color {
    switch status {
    case "live": .green
    case "analyzing": .orange
    case "error": .red
    default: .blue
    }
  }
}

struct ControlRow: View {
  @ObservedObject var store: SurfaceStore
  let control: SurfaceControl

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        Button(control.emoji) { store.copy(control) }
          .buttonStyle(.plain).font(.system(size: 17)).frame(width: 24)
        VStack(alignment: .leading, spacing: 2) {
          Text(control.label).font(.system(size: 12, weight: .medium))
            .foregroundStyle(accentColor(control.color)).lineLimit(2)
          Text(control.help).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        if control.kind == "toggle" {
          editor
        }
      }
      if control.kind != "toggle" {
        HStack(spacing: 12) {
          Color.clear.frame(width: 24, height: 1)
          editor.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder private var editor: some View {
    switch control.kind {
    case "toggle":
      Toggle(
        "",
        isOn: Binding(
          get: { store.effective(control).enabled },
          set: { store.setEnabled($0, for: control) }
        )
      ).labelsHidden().toggleStyle(.switch)
    case "choice":
      if control.options.count <= 3
        && control.options.reduce(0, { $0 + $1.count }) <= 36
      {
        choicePicker.pickerStyle(.segmented)
      } else {
        choicePicker.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
      }
    case "slider":
      VStack(alignment: .trailing, spacing: 1) {
        Text(formatted(store.effective(control).value))
          .font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(
            .secondary)
        Slider(
          value: Binding(
            get: { store.effective(control).value },
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
        get: { store.effective(control).selected.first ?? "" },
        set: { store.setSelection($0, for: control) }
      )
    ) {
      ForEach(control.options, id: \.self) { Text($0).tag($0) }
    }
    .labelsHidden().controlSize(.small)
  }

  private func formatted(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
  }

  private func accentColor(_ color: String) -> Color {
    switch color {
    case "green": .green
    case "orange": .orange
    case "purple": .purple
    case "gray": .secondary
    default: .blue
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let configuration: Configuration
  private var panel: NSPanel?
  private var store: SurfaceStore?

  init(configuration: Configuration) { self.configuration = configuration }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let store = SurfaceStore(configuration: configuration)
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: overlayWidth, height: 300),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = NSHostingView(rootView: OverlayView(store: store))
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    store.onSurfaceChange = { [weak panel] surface in
      guard let panel else { return }
      let controlsHeight = surface.controls.reduce(CGFloat.zero) { height, control in
        height + (control.kind == "toggle" ? 62 : 82)
      }
      panel.setContentSize(
        NSSize(width: overlayWidth, height: min(160 + max(controlsHeight, 62), 580)))
      Self.anchor(panel)
    }
    Self.anchor(panel)
    panel.orderFrontRegardless()
    self.store = store
    self.panel = panel
  }

  private static func anchor(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    panel.setFrameOrigin(
      NSPoint(
        x: screen.visibleFrame.maxX - panel.frame.width - 18,
        y: screen.visibleFrame.minY + 18
      ))
  }
}

let application = NSApplication.shared
let delegate = AppDelegate(configuration: Configuration.parse())
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
