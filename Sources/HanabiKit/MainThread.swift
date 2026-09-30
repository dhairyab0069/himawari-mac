import Foundation

/// Runs `body` as main-actor code, for callbacks AppKit already delivers on the main
/// thread (timers, observers on `.main`, event monitors). It does what
/// `onMainActor` does, minus asking the Swift runtime which executor is
/// current: that check crashed Hanabi (SIGSEGV inside `swift_task_isMainExecutor`)
/// from plain main-thread timers. Checking the thread is enough here.
public func onMainActor<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    precondition(Thread.isMainThread, "onMainActor called off the main thread")
    return try withoutActuallyEscaping(body) { fn in
        try unsafeBitCast(fn, to: (() throws -> T).self)()
    }
}
