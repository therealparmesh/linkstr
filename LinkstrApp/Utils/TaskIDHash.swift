import Foundation

extension Collection where Element: Hashable {
  var stableTaskID: Int {
    Set(self).hashValue
  }
}
