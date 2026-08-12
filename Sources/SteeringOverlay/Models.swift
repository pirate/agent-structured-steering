import Foundation

struct ObserverInfo: Codable, Equatable {
  let status: String
  // UI writes must preserve this or every click invalidates the observer's stable baseline.
  let promptVersion: String?
}

struct SurfaceControl: Codable, Equatable {
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

extension SurfaceControl: Identifiable {}

struct SteeringSurface: Codable, Equatable {
  var revision: Int
  let threadId: String
  let sessionTitle: String?
  let projectName: String?
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

struct ActiveSession: Decodable {
  let threadId: String
}

struct SurfaceSession: Identifiable, Equatable {
  let surface: SteeringSurface
  let directory: URL

  var id: String { surface.threadId }
}

struct AppConfiguration {
  let activePath: String

  static func parse() -> AppConfiguration {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--active"), arguments.indices.contains(index + 1)
    else {
      fputs("usage: SteeringOverlay --active PATH\n", stderr)
      exit(2)
    }
    return AppConfiguration(activePath: arguments[index + 1])
  }
}
