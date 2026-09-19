//
//  WaitUntil.swift
//  PurchaseTestSupport
//

/// Waits for `condition`, for at most `timeout`, returning as soon as it holds.
///
/// Five seconds unless told otherwise. It costs nothing when the condition holds, which
/// is every time a suite is green; a tighter ceiling on a *positive* wait is only a
/// flake waiting for a loaded machine.
///
/// For the few things a test cannot await directly — a transaction delivered through
/// the updates stream reaches the store on another task. **Not a sleep**: it costs
/// nothing when the condition already holds, and the assertion that follows is what
/// fails, so the failure says what was expected rather than "timed out".
///
///     store.deliver(pro)
///     await waitUntil { purchases.standing.ownership(of: "pro") != nil }
///     #expect(purchases.standing.ownership(of: "pro") != nil)
@discardableResult
public func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
        if await condition() { return true }
        if clock.now >= deadline { return false }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(1))
    }
}
