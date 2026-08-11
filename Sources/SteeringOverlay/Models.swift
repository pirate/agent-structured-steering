import AppKit
import Foundation

struct ObserverInfo: Codable, Equatable {
  let status: String
  let model: String
  let message: String
}

struct SurfaceControl: Codable, Equatable {
  let id: String
  let label: String
  let kind: String
  let help: String
  let emoji: String
  let color: String
  var enabled: Bool
  var selected: [String]
  let options: [String]
  var value: Double
  let min: Double
  let max: Double
  let step: Double
}

extension SurfaceControl: Identifiable {}

struct SteeringSurface: Codable, Equatable {
  var revision: Int
  let threadId: String
  let sessionTitle: String?
  let activeCount: Int?
  let summary: String
  let observer: ObserverInfo
  var controls: [SurfaceControl]
}

struct SteeringEvent: Codable {
  let timestamp: String
  let revision: Int
  let controlId: String
  let label: String
  let enabled: Bool
  let selected: [String]
  let value: Double
  let source: String
}

struct ActiveSession: Codable, Equatable {
  let threadId: String
  let statePath: String
  let eventsPath: String
  let source: String
}

struct Configuration {
  let activePath: String

  static func parse() -> Configuration {
    var activePath: String?
    var index = 1
    let arguments = CommandLine.arguments
    while index < arguments.count {
      switch arguments[index] {
      case "--active" where index + 1 < arguments.count:
        activePath = arguments[index + 1]
        index += 2
      default:
        index += 1
      }
    }
    guard let activePath else {
      fputs("usage: SteeringOverlay --active PATH\n", stderr)
      exit(2)
    }
    return Configuration(activePath: activePath)
  }
}
