import AVFoundation

extension PlayableMedia {
  func loadVideoAsset() async -> AVURLAsset? {
    let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    let asset = AVURLAsset(url: playbackURL, options: options)

    do {
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      if videoTracks.isEmpty {
        // HLS may have no asset tracks until playback, including downloaded packages.
        let isHLS = playbackURL.absoluteString.lowercased().contains(".m3u8") || asset.assetCache != nil
        guard isHLS, try await asset.load(.isPlayable) else { return nil }
      }
      guard !Task.isCancelled else { return nil }
      return asset
    } catch {
      return nil
    }
  }
}
