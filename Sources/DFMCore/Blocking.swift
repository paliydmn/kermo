import Foundation

/// Off-main work that can wait in the kernel: file system calls (a dead NFS/SMB mount never answers), child processes,
/// a hung server's ssh. Not `Task.detached`: that runs on the Swift concurrency pool, one thread per core, and a few
/// such calls stalled every task in the app, local listings too. GCD starts another thread when one blocks.
/// ponytail: GCD has a ceiling too (64 threads), so what repeats on its own — folder listings and their symlink notes
/// (`Coalesced`), the sidebar's volume reload (`SingleFlight`) — runs one at a time. Another limit if another caller starts piling up.
public enum Blocking {
    public static func run<T: Sendable>(_ qos: DispatchQoS.QoSClass = .default, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in DispatchQueue.global(qos: qos).async { c.resume(returning: work()) } }
    }

    public static func run<T: Sendable>(_ qos: DispatchQoS.QoSClass = .default, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in DispatchQueue.global(qos: qos).async { c.resume(with: Result { try work() }) } }
    }
}

/// `Blocking.run`, one per key at a time: callers that come while one runs wait for one more run, started when it
/// returns, and all get its result. Listing a folder on a dead mount hangs for good; every reload, tab switch or
/// other panel showing it would take another thread until GCD has none left. Now it's one per folder.
@MainActor public final class Coalesced<T: Sendable> {
    private var queued: [String: (work: @Sendable () -> T, waiters: [CheckedContinuation<T, Never>])] = [:]
    private var running: Set<String> = []

    public init() {}

    public func run(_ key: String, _ qos: DispatchQoS.QoSClass = .default, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { c in
            queued[key, default: (work, [])].waiters.append(c)
            guard running.insert(key).inserted else { return }
            Task {
                while let q = queued.removeValue(forKey: key) {
                    let r = await Blocking.run(qos, q.work)
                    for c in q.waiters { c.resume(returning: r) }
                }
                running.remove(key)
            }
        }
    }
}
