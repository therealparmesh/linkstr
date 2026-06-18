import Foundation

extension Collection where Element == String {
  var stableTaskID: String {
    Set(self)
      .sorted()
      .map { "\($0.count):\($0)" }
      .joined(separator: "|")
  }
}
