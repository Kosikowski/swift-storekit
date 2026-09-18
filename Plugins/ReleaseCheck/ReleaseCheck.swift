//
//  ReleaseCheck.swift
//  ReleaseCheck
//
//  `swift package release-check`: proves that nothing able to grant a purchase is in a
//  release build.
//
//  It builds the package twice and looks at compiled symbols — not at text, because
//  build metadata names every source file whatever the configuration. Every name the
//  simulated store goes by must be **found** in the debug build and **absent** from
//  the release one.
//
//  **A check that cannot fail proves nothing, and this one's two predecessors could
//  not.** Both were shell scripts that went looking for the build's files by the shape
//  of their paths. The first searched a directory the build system had stopped using.
//  The second picked files whose path contained `Release`, which under SwiftPM's older
//  layout (`.build/<triple>/release`) is none of them, so it searched nothing and
//  reported clean; its own control — "the same search must find the store in a debug
//  build" — was satisfied by the word `Debug` in `PurchaseDebugUI`. And one of its
//  three names was misspelt (`16PurchaseTestKit…`; the module's name is fifteen
//  letters long), so `Scenario` had never been looked for at all.
//
//  So, three rules, each the answer to one of those:
//
//  · **The build says what it built.** This is a plugin rather than a script for that
//    reason: `packageManager.build` hands back the libraries of *that* configuration,
//    and nothing is inferred from a path. Where the build system reports none — the
//    older one compiles a library to loose objects — they are taken from that
//    configuration's own directory, never matched by name across the build folder.
//  · **The release search has a control of its own.** It must find something that
//    ships in every configuration (`ManualClock`). Finding nothing forbidden in a
//    search that can see nothing is not a pass.
//  · **Every forbidden name is controlled separately.** Each must turn up in the debug
//    build, so a name that is misspelt, or that a rename has left behind, fails here
//    instead of quietly guarding nothing.
//
//  A macro was considered for this and cannot do it: a macro sees source, at compile
//  time, and the question is about a finished binary. What a macro could enforce —
//  that the simulated store is not mentioned in a release build — `#if DEBUG` round
//  the whole file already does, as a compile error, without a dependency on
//  swift-syntax in a package that has none.
//

import Foundation
import PackagePlugin

@main
struct ReleaseCheck: CommandPlugin {
    /// What must not ship, as it appears in a mangled symbol. Length-prefixed where
    /// the bare word would be too common to mean anything.
    private static let forbidden = ["SimulatedStoreFront", "PurchaseDebugPanel", "15PurchaseTestKit8Scenario"]

    /// Ships in every configuration, from the same module as the simulated store: if
    /// the release search cannot see this, it cannot see anything.
    private static let control = "15PurchaseTestKit11ManualClock"

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let nm = try context.tool(named: "nm").url

        let debug = try symbols(in: .debug, context: context, nm: nm)
        let release = try symbols(in: .release, context: context, nm: nm)

        let blind = Self.forbidden.filter { name in !debug.contains { $0.contains(name) } }
        guard blind.isEmpty, debug.contains(where: { $0.contains(Self.control) }) else {
            throw Failure(
                """
                VACUOUS — a debug build must contain the simulated store, and the search cannot find \
                \(blind.isEmpty ? Self.control : blind.joined(separator: ", ")) in it. Finding nothing in a \
                release build would prove nothing. Fix the names in this plugin.
                """)
        }
        guard release.contains(where: { $0.contains(Self.control) }) else {
            throw Failure(
                """
                VACUOUS — the release search cannot find \(Self.control), which ships in every \
                configuration, so it is not looking at the release build at all.
                """)
        }
        let found = Self.forbidden.filter { name in release.contains { $0.contains(name) } }
        guard found.isEmpty else {
            throw Failure("the simulated store is present in a release build: \(found.joined(separator: ", "))")
        }
        print("release-check: clean — \(Self.forbidden.count) names found in debug, none in release, and the release search does see \(Self.control)")
    }

    // MARK: - Private

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = "release-check: \(description)" }
    }

    /// Every symbol in everything one configuration built.
    private func symbols(
        in configuration: PackageManager.BuildConfiguration, context: PluginContext, nm: URL
    ) throws -> [String] {
        let result = try packageManager.build(
            .all(includingTests: false), parameters: .init(configuration: configuration, logging: .concise))
        guard result.succeeded else { throw Failure("the \(configuration) build failed:\n\(result.logText)") }

        var files = result.builtArtifacts.map(\.url)
        if files.isEmpty { files = looseObjects(of: configuration, context: context) }
        guard !files.isEmpty else { throw Failure("VACUOUS — the \(configuration) build reported nothing to search") }
        return try files.flatMap { try symbols(in: $0, nm: nm) }
    }

    /// The older build system compiles an automatic library to loose objects and
    /// reports no artifact for it. They sit in the configuration's own directory beside
    /// this plugin's, `<scratch>/<configuration>` — a guess at a layout, which is what
    /// went wrong before, and is safe here only because both searches are controlled:
    /// guessed wrong, this finds nothing and the check fails as vacuous.
    private func looseObjects(of configuration: PackageManager.BuildConfiguration, context: PluginContext) -> [URL] {
        // <scratch>/plugins/<plugin>/outputs
        let scratch = context.pluginWorkDirectoryURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = scratch.appending(path: "\(configuration)").resolvingSymlinksInPath()
        guard let walk = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "o" }
    }

    /// Plain `nm`, not `nm -a`: the debugger's entries name every source *file*, and a
    /// file that compiled to nothing is exactly what is wanted here.
    private func symbols(in file: URL, nm: URL) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = nm
        process.arguments = [file.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read to the end before waiting: a library's symbols overfill a pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
