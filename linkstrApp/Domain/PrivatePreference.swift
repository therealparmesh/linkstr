import CryptoKit
import Foundation
import NostrSDK

enum PrivatePreference: Codable, Equatable {
  case alias(pubkey: String, name: String?)
  case archive(sessionID: String, archived: Bool)

  var key: String {
    switch self {
    case .alias(let pubkey, _): return "alias:\(pubkey)"
    case .archive(let sessionID, _): return "archive:\(sessionID)"
    }
  }

  var isValid: Bool {
    switch self {
    case .alias(let pubkey, let name):
      return NostrValueNormalizer.normalizedPubkeyHex(pubkey) == pubkey
        && (name == nil || name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    case .archive(let sessionID, _):
      return !sessionID.isEmpty && sessionID == sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }
}

struct PrivatePreferenceCodec: EventCreating, SignatureVerifying {
  static let kind = EventKind.unknown(30_078)
  static let namespace = "linkstr/preferences/v1/"

  func identifier(for preference: PrivatePreference, keypair: Keypair) -> String {
    // Keyed identifiers keep contact and session IDs out of public event tags.
    let digest = HMAC<SHA256>.authenticationCode(
      for: Data((Self.namespace + preference.key).utf8),
      using: SymmetricKey(data: keypair.privateKey.dataRepresentation)
    )
    return Self.namespace + digest.map { String(format: "%02x", $0) }.joined()
  }

  func event(for preference: PrivatePreference, keypair: Keypair, createdAt: Int64) throws -> NostrEvent {
    guard preference.isValid else { throw PrivatePreferenceError.invalidEvent }
    guard let content = String(data: try JSONEncoder().encode(preference), encoding: .utf8) else {
      throw PrivatePreferenceError.invalidEvent
    }
    let identifierTag = try JSONDecoder().decode(
      Tag.self, from: JSONEncoder().encode(["d", identifier(for: preference, keypair: keypair)])
    )
    return try NostrEvent.Builder<NostrEvent>(kind: Self.kind)
      .createdAt(createdAt)
      .appendTags(identifierTag)
      .content(encrypt(plaintext: content, privateKeyA: keypair.privateKey, publicKeyB: keypair.publicKey))
      .build(signedBy: keypair)
  }

  func preference(from event: NostrEvent, keypair: Keypair) throws -> PrivatePreference {
    guard event.kind == Self.kind, event.pubkey == keypair.publicKey.hex,
      event.id == event.calculatedId, let signature = event.signature,
      let identifier = event.firstValueForRawTagName("d"), identifier.hasPrefix(Self.namespace)
    else { throw PrivatePreferenceError.invalidEvent }
    try verifySignature(signature, for: event.id, withPublicKey: event.pubkey)
    let content = try decrypt(payload: event.content, privateKeyA: keypair.privateKey, publicKeyB: keypair.publicKey)
    let preference = try JSONDecoder().decode(PrivatePreference.self, from: Data(content.utf8))
    guard preference.isValid, identifier == self.identifier(for: preference, keypair: keypair) else {
      throw PrivatePreferenceError.invalidEvent
    }
    return preference
  }
}

enum PrivatePreferenceError: Error {
  case invalidEvent
}
