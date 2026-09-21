//
//  RealStoreKit.swift
//  DemoTests
//
//  StoreKit's test environment is one, shared by every session and outliving the process,
//  so every suite that uses it runs one test at a time. `.serialized` orders only a suite's
//  own tests, so they are one suite's: this one.
//

import Testing

@Suite(.serialized)
enum RealStoreKit {
    /// Built with Xcode 27's tools. The test environment is Xcode's, and on the same macOS it
    /// does things with Xcode 26.6 that it does not with 27.0 (spike/README.md). A test cannot
    /// ask Xcode its version, so it asks the compiler: Xcode 27 ships Swift 6.4.
    nonisolated static var builtWithXcode27: Bool {
        #if compiler(>=6.4)
        true
        #else
        false
        #endif
    }
}
