import Foundation

/// Serialize follow-list changes so each update starts from the last completed one.
@MainActor
final class ContactMutationQueue {
  private var tail: Task<Bool, Never>?
  private var tasks: [UUID: Task<Bool, Never>] = [:]

  func run(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
    let predecessor = tail
    let id = UUID()
    let task = Task { @MainActor in
      _ = await predecessor?.value
      guard !Task.isCancelled else { return false }
      return await operation()
    }
    tasks[id] = task
    tail = task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    tasks.removeValue(forKey: id)
    if tasks.isEmpty { tail = nil }
    return result
  }

  func cancel() {
    tasks.values.forEach { $0.cancel() }
    tasks.removeAll()
    tail = nil
  }
}
