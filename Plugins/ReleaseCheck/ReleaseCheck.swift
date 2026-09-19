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
//  **What it looks for is a module, not a list of names.** PurchaseSimulator is guarded
//  whole, so in a release build it must contribute *nothing*: no symbol anywhere may
//  mention it. A list of the types that can grant a purchase is a list somebody has to
//  remember to extend; a new one, under a new name, would have passed. The store's own
//  name is kept as well, in case it is ever moved to a module this does not watch, and
//  so is the debug panel's content: the panel's *name* is in every build, on purpose,
//  and what it draws must not be.
//
//  **And PurchaseTestKit must not be in an app at all**, debug or release: it is what
//  tests import, none of it is guarded, and Xcode links a package product into every
//  configuration of a target or none. Its control is the hosted test bundle inside the
//  debug app, which is where it belongs.
//
//  **And it looks at the app, not only at the package** (`--app`, `--debug-app`). What
//  ships is Xcode's Release build, and Xcode gives a package `DEBUG` by the *name* of
//  the app's build configuration — a heuristic nobody documents, and the one link a
//  check of SwiftPM's own release build cannot test. `make demo` builds the Demo both
//  ways and hands both here: every Mach-O in the bundle, by symbol and by string.
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
    /// What must not ship, as it appears in a mangled symbol: the module that is guarded
    /// whole (length-prefixed, as the mangling has it), the store by name, and what the
    /// debug panel draws.
    private static let forbidden = ["17PurchaseSimulator", "SimulatedStoreFront", "12PanelContent"]

    /// Ships in every configuration, and is built by the same build: if the release
    /// search cannot see this, it cannot see anything. The module alone, and not
    /// `…11StoreLaunch` after it: the mangling abbreviates a word it has already spelt, so
    /// the type's name is not in its own symbol. (This plugin's control on its own names
    /// is what said so.)
    private static let control = "14PurchaseLaunch"

    /// What tests import. Not guarded, because it grants nothing. An app that links it
    /// does not build (D34); this is for whatever gets past that.
    private static let testsOnly = "15PurchaseTestKit"

    /// In a built app, additionally: what a scenario is called on a command line and in
    /// the environment. Strings, which survive where symbols are stripped.
    private static let forbiddenInAnApp = forbidden + ["PurchaseScenario", "PURCHASE_SCENARIO"]

    /// What any app using the package carries, in any configuration.
    private static let appControl = "PurchaseStore"

    /// The debug panel is a product, and an app need not link it: the first app moved
    /// onto this package does not, and was called vacuous for want of a panel it never
    /// had. So the panel's name is looked for in a debug app only if the panel's *module*
    /// is there. In the release app it is forbidden whichever; and its spelling is
    /// controlled by the package's own check, and by any app that does link it.
    private static let panel = "12PanelContent"
    private static let panelModule = "15PurchaseDebugUI"

    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let nm = try context.tool(named: "nm").url
        if arguments.contains("--app") || arguments.contains("--debug-app") {
            try checkApps(arguments: arguments, context: context, nm: nm)
            return
        }

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

    // MARK: - A built app

    /// `--app <Release .app> --debug-app <Debug .app>`. The debug app is the control:
    /// the same search has to find the simulated store where it is known to be.
    private func checkApps(arguments: [String], context: PluginContext, nm: URL) throws {
        func value(after flag: String) throws -> URL {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                throw Failure("\(flag) <path to a built .app> is needed: both --app and --debug-app, one as the control for the other")
            }
            let path = arguments[index + 1]
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : context.package.directoryURL.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure("there is nothing at \(url.path)") }
            return url
        }
        let strings = try context.tool(named: "strings").url
        let release = try contents(ofApp: value(after: "--app"), nm: nm, strings: strings)
        let debug = try contents(ofApp: value(after: "--debug-app"), nm: nm, strings: strings)

        let linksThePanel = debug.contains { $0.contains(Self.panelModule) }
        let expected = Self.forbiddenInAnApp.filter { $0 != Self.panel || linksThePanel }
        let blind = expected.filter { name in !debug.contains { $0.contains(name) } }
        guard blind.isEmpty else {
            throw Failure(
                """
                VACUOUS — the debug app must contain the simulated store, and the search cannot find \
                \(blind.joined(separator: ", ")) in it. Was it built in a configuration whose name begins with Debug?
                """)
        }
        guard release.contains(where: { $0.contains(Self.appControl) }) else {
            throw Failure("VACUOUS — the search cannot find \(Self.appControl) in the release app, so it is not reading it at all.")
        }
        let found = Self.forbiddenInAnApp.filter { name in release.contains { $0.contains(name) } }
        guard found.isEmpty else {
            throw Failure("the simulated store is present in the RELEASE APP: \(found.joined(separator: ", "))")
        }
        // The test kit's control is the hosted test bundle, which a debug app built for
        // testing carries inside it. Without one the name below is unchecked, and an
        // unchecked name guards nothing.
        guard debug.contains(where: { $0.contains(Self.testsOnly) }) else {
            throw Failure(
                """
                VACUOUS — \(Self.testsOnly) is nowhere in the debug app, so its absence from the release \
                app proves nothing. Build the debug app with build-for-testing, so that its hosted test \
                bundle is inside it.
                """)
        }
        guard !release.contains(where: { $0.contains(Self.testsOnly) }) else {
            throw Failure(
                """
                PurchaseTestKit is linked into the RELEASE APP. It is for test targets: nothing in it is \
                guarded, and Xcode links a package product into every configuration of a target or none.
                """)
        }
        let panelNote = linksThePanel ? "" : " (it does not link the debug panel)"
        print(
            "release-check: the app is clean — \(expected.count) names found in the debug app\(panelNote), none in the release app, which carries \(Self.appControl) and nothing of the test kit"
        )
    }

    /// Every symbol and every string in every Mach-O file of the bundle. In a debug-type
    /// Xcode build the code is not in the main executable at all but in a `.debug.dylib`
    /// beside it, so nothing is taken for granted about where to look.
    private func contents(ofApp app: URL, nm: URL, strings: URL) throws -> [String] {
        guard let walk = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var lines: [String] = []
        for case let file as URL in walk {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, isMachO(file) else { continue }
            lines += try output(of: nm, [file.path])
            lines += try output(of: strings, ["-a", file.path])
        }
        return lines
    }

    private func isMachO(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file), let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        try? handle.close()
        let word = magic.withUnsafeBytes { $0.load(as: UInt32.self) }
        // Thin, either byte order, 32- or 64-bit; and fat.
        return [0xfeed_face, 0xfeed_facf, 0xcefa_edfe, 0xcffa_edfe, 0xcafe_babe, 0xbeba_feca].contains(word)
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
        try output(of: nm, [file.path])
    }

    private func output(of tool: URL, _ arguments: [String]) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = tool
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read to the end before waiting: a library's symbols overfill a pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
