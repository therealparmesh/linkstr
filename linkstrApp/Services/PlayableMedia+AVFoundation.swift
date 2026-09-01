import AVFoundation

extension PlayableMedia {
  func loadVideoAsset() async -> AVURLAsset? {
    let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    let asset = AVURLAsset(url: playbackURL, options: options)

    do {
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard !Task.isCancelled, !videoTracks.isEmpty else { return nil }
      return asset
    } catch {
      return nil
    }
  }
}
