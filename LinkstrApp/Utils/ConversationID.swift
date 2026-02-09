import CryptoKit
import Foundation

enum ConversationID {
  static func deterministic(_ lhsPubkey: String, _ rhsPubkey: String) -> String {
    let sorted = [lhsPubkey.lowercased(), rhsPubkey.lowercased()].sorted().joined(separator: ":")
    let digest = SHA256.hash(data: Data(sorted.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined()
  }
}
