import CryptoKit
import Foundation
import NostrSDK

struct PushDeviceRegistration: Equatable {
  let deviceToken: String
  let apnsEnvironment: String
}

struct PushEnqueueRequest: Equatable {
  let notificationType: String
  let eventID: String
  let conversationID: String
  let recipientPubkeys: [String]
  let emoji: String?
}

enum PushAPIClientError: LocalizedError {
  case missingBaseURL
  case invalidResponse
  case server(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .missingBaseURL:
      return "push service base url is not configured."
    case .invalidResponse:
      return "push service returned an invalid response."
    case .server(let statusCode, let message):
      let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        return "push service request failed with status \(statusCode)."
      }
      return "push service request failed with status \(statusCode): \(trimmed)"
    }
  }
}

private struct RegisterDeviceRequestBody: Encodable {
  let deviceToken: String
  let apnsEnvironment: String

  enum CodingKeys: String, CodingKey {
    case deviceToken = "device_token"
    case apnsEnvironment = "apns_environment"
  }
}

private struct UnregisterDeviceRequestBody: Encodable {
  let deviceToken: String

  enum CodingKeys: String, CodingKey {
    case deviceToken = "device_token"
  }
}

private struct SyncArchivedConversationsRequestBody: Encodable {
  let archivedConversationIDs: [String]

  enum CodingKeys: String, CodingKey {
    case archivedConversationIDs = "archived_conversation_ids"
  }
}

private struct EnqueuePushRequestBody: Encodable {
  let notificationType: String
  let eventID: String
  let conversationID: String
  let recipientPubkeys: [String]
  let emoji: String?

  enum CodingKeys: String, CodingKey {
    case notificationType = "notification_type"
    case eventID = "event_id"
    case conversationID = "conversation_id"
    case recipientPubkeys = "recipient_pubkeys"
    case emoji
  }
}

@MainActor
final class PushAPIClient {
  static let shared = PushAPIClient()

  private init() {}

  var isConfigured: Bool {
    Self.baseURL != nil
  }

  func registerDevice(_ registration: PushDeviceRegistration, signedBy keypair: Keypair)
    async throws {
    try await performRequest(
      path: "/v1/devices/register",
      method: "POST",
      body: RegisterDeviceRequestBody(
        deviceToken: registration.deviceToken,
        apnsEnvironment: registration.apnsEnvironment
      ),
      signedBy: keypair
    )
  }

  func unregisterDevice(deviceToken: String, signedBy keypair: Keypair) async throws {
    try await performRequest(
      path: "/v1/devices/unregister",
      method: "POST",
      body: UnregisterDeviceRequestBody(deviceToken: deviceToken),
      signedBy: keypair
    )
  }

  func syncArchivedConversations(_ conversationIDs: [String], signedBy keypair: Keypair)
    async throws {
    try await performRequest(
      path: "/v1/conversations/archive-state",
      method: "PUT",
      body: SyncArchivedConversationsRequestBody(archivedConversationIDs: conversationIDs),
      signedBy: keypair
    )
  }

  func enqueuePush(_ request: PushEnqueueRequest, signedBy keypair: Keypair) async throws {
    try await performRequest(
      path: "/v1/push",
      method: "POST",
      body: EnqueuePushRequestBody(
        notificationType: request.notificationType,
        eventID: request.eventID,
        conversationID: request.conversationID,
        recipientPubkeys: request.recipientPubkeys,
        emoji: request.emoji
      ),
      signedBy: keypair
    )
  }

  private func performRequest<RequestBody: Encodable>(
    path: String,
    method: String,
    body: RequestBody,
    signedBy keypair: Keypair
  ) async throws {
    guard let baseURL = Self.baseURL else {
      throw PushAPIClientError.missingBaseURL
    }

    let requestURL = baseURL.appending(path: path)
    let bodyData = try JSONEncoder().encode(body)

    var request = URLRequest(url: requestURL)
    request.httpMethod = method
    request.httpBody = bodyData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      try authorizationHeader(
        method: method,
        path: requestURL.path,
        bodyData: bodyData,
        signedBy: keypair
      ),
      forHTTPHeaderField: "Authorization"
    )

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw PushAPIClientError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let message = (try? JSONDecoder().decode(ServerErrorResponse.self, from: data).error) ?? ""
      throw PushAPIClientError.server(statusCode: httpResponse.statusCode, message: message)
    }
  }

  private func authorizationHeader(
    method: String,
    path: String,
    bodyData: Data,
    signedBy keypair: Keypair
  ) throws -> String {
    let payloadHashHex = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()
    let nonce = UUID().uuidString.lowercased()
    let authEvent = try NostrEvent.Builder<NostrEvent>(kind: .unknown(27235))
      .content("")
      .appendTags(try customTag(name: "method", value: method))
      .appendTags(try customTag(name: "path", value: path))
      .appendTags(try customTag(name: "payload_sha256", value: payloadHashHex))
      .appendTags(try customTag(name: "nonce", value: nonce))
      .build(signedBy: keypair)
    let authData = try JSONEncoder().encode(authEvent)
    return "Nostr \(authData.base64EncodedString())"
  }

  private func customTag(name: String, value: String) throws -> Tag {
    let rawTag = [name, value]
    let data = try JSONEncoder().encode(rawTag)
    return try JSONDecoder().decode(Tag.self, from: data)
  }

  private struct ServerErrorResponse: Decodable {
    let error: String
  }

  private static var baseURL: URL? {
    let environmentValue =
      ProcessInfo.processInfo.environment["LINKSTR_PUSH_SERVICE_BASE_URL"]?.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    if let environmentValue, !environmentValue.isEmpty {
      return URL(string: environmentValue)
    }

    let infoValue = Bundle.main.object(forInfoDictionaryKey: "LinkstrPushServiceBaseURL") as? String
    let trimmedInfoValue = infoValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedInfoValue.isEmpty else { return nil }
    return URL(string: trimmedInfoValue)
  }
}
