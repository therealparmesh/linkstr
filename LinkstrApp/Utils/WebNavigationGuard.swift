import Foundation

enum WebNavigationGuard {
  private static let allowedSchemes = Set(["http", "https", "about", "data", "blob"])

  static func allowsNavigation(to url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return allowedSchemes.contains(scheme)
  }
}
