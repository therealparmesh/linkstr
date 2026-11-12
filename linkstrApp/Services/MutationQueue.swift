import Foundation

/// Serialize changes to the same record while allowing independent records to proceed.
@MainActor
final class MutationQueue {
  private var tails: [String: (id: UUID, task: Task<Bool, Never>)] = [:]
  private var tasks: [UUID: Task<Bool, Never>] = [:]

  func run(key: String = "", _ operation: @escaping @MainActor () async -> Bool) async -> Bool {
    let predecessor = tails[key]?.task
    let id = UUID()
    let task = Task { @MainActor in
      _ = await predecessor?.value
      guard !Task.isCancelled else { return false }
      return await operation()
    }
    tasks[id] = task
    tails[key] = (id, task)
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    tasks.removeValue(forKey: id)
    if tails[key]?.id == id { tails.removeValue(forKey: key) }
    return result
  }

  func cancel() {
    tasks.values.forEach { $0.cancel() }
    tasks.removeAll()
    tails.removeAll()
  }
}
