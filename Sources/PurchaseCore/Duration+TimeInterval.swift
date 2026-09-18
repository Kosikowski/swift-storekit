//
//  Duration+TimeInterval.swift
//  PurchaseCore
//
//  Layer: Domain
//
//  A `Duration` as the seconds a `Date` is moved by.
//
//  Durations are what a catalogue and a test are written in; dates are what the store
//  deals in. The conversion was written out wherever the two met — the store's grace,
//  a trial's end, the simulated store's ages, the manual clock — and four copies of one
//  sum are four chances for the store, the trial and the test clock to disagree about
//  the same fortnight. `package`, so that the test kit shares it and no app sees it.
//

package import Foundation

extension Duration {
    /// In seconds, to the precision a `Double` has.
    package var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
