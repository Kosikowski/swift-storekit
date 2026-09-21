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
enum RealStoreKit {}
