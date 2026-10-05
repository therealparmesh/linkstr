import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let linkstrBackup = UTType(exportedAs: "com.parmscript.linkstr.backup", conformingTo: .data)
}

struct BackupDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.linkstrBackup] }
  let data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else { throw BackupError.invalidFile }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension BackupWorker {
  func read(_ url: URL) throws -> LinkstrBackup {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<LinkstrBackup, Error> = .failure(BackupError.invalidFile)
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
      result = Result {
        let values = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw BackupError.invalidFile }
        guard let size = values.fileSize, size <= LinkstrBackup.maximumFileBytes else { throw BackupError.tooLarge }
        return try decode(Data(contentsOf: coordinatedURL))
      }
    }
    if let coordinationError { throw coordinationError }
    return try result.get()
  }

  func decode(_ data: Data) throws -> LinkstrBackup {
    guard data.count <= LinkstrBackup.maximumFileBytes else { throw BackupError.tooLarge }
    struct Header: Decodable { let version: Int }
    do {
      let decoder = JSONDecoder()
      let header = try decoder.decode(Header.self, from: data)
      guard header.version <= 1 else { throw BackupError.newerVersion }
      let backup = try decoder.decode(LinkstrBackup.self, from: data)
      try backup.validate()
      return backup
    } catch is DecodingError {
      throw BackupError.invalidFile
    }
  }
}
