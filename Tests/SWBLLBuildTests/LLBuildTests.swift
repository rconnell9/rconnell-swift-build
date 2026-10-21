//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Testing
import SWBLLBuild
import SWBTestSupport
import SWBUtil

import struct SWBLLBuild.Diagnostic
import Foundation
import Synchronization

fileprivate class LoggingDelegate: BuildSystemDelegate {
    var buildSystem: BuildSystem? = nil
    let fs: (any SWBLLBuild.FileSystem)?
    let fsProxy: any FSProxy
    private struct Output: Sendable {
        var log: [String] = []
        var errors: [String] = []
    }
    private let output = SWBMutex<Output>(.init())
    let ignoreStatusChanges: Bool

    var log: [String] {
        output.withLock { $0.log }
    }

    var errors: [String] {
        output.withLock { $0.errors }
    }

    init(fs: any FSProxy, ignoreStatusChanges: Bool = false) {
        self.fs = SWBLLBuild.FileSystemImpl(fs)
        self.fsProxy = fs
        self.ignoreStatusChanges = ignoreStatusChanges
    }

    func append(log: String) {
        output.withLock { output in
            output.log.append(log)
        }
    }

    func lookupTool(_ name: String) -> (any Tool)? {
        return nil
    }

    func hadCommandFailure() {
        output.withLock { output in
            output.log.append("had-command-failure")
        }
        buildSystem?.cancel()
    }

    func handleDiagnostic(_ diagnostic: Diagnostic) {
        output.withLock { output in
            output.log.append("\(diagnostic.kind): \(diagnostic.message)")
            output.errors.append("\(diagnostic.kind): \(diagnostic.message)")
        }
    }

    func commandStatusChanged(_ command: Command, kind: CommandStatusKind) {
        if !ignoreStatusChanges {
            output.withLock { output in
                output.log.append("command-status-changed: \(command.name), to: \(kind)")
            }
        }
    }
    func commandPreparing(_ command: Command) {
        output.withLock { output in
            output.log.append("command-preparing: \(command.name)")
        }
    }
    func commandStarted(_ command: Command) {
        output.withLock { output in
            output.log.append("command-started: \(command.name)")
        }
    }
    func shouldCommandStart(_ command: Command) -> Bool {
        output.withLock { output in
            output.log.append("should-command-start: \(command.name)")
        }
        return true
    }
    func commandFinished(_ command: Command, result: CommandResult) {
        output.withLock { output in
            output.log.append("command-finished: \(command.name)")
        }
    }
    func commandFoundDiscoveredDependency(_ command: Command, path: String, kind: DiscoveredDependencyKind) {
        output.withLock { output in
            output.log.append("command-found-discovered-dependency: \(path) \(kind)")
        }
    }
    func commandHadError(_ command: Command, message: String) {
        output.withLock { output in
            output.log.append("command-had-error: \(command.name): \(message)")
            output.errors.append("command-had-error: \(command.name): \(message)")
        }
    }
    func commandHadNote(_ command: Command, message: String) {
        output.withLock { output in
            output.log.append("command-had-note: \(command.name): \(message)")
        }
    }
    func commandHadWarning(_ command: Command, message: String) {
        output.withLock { output in
            output.log.append("command-had-warning: \(command.name): \(message)")
        }
    }
    func commandProcessStarted(_ command: Command, process: ProcessHandle) {
        output.withLock { output in
            output.log.append("command-process-started: \(command.name) -- \(command.description)")
        }
    }
    func commandProcessHadError(_ command: Command, process: ProcessHandle, message: String) {
        output.withLock { output in
            output.log.append("command-process-error: \(message)")
        }
    }
    func commandProcessHadOutput(_ command: Command, process: ProcessHandle, data: [UInt8]) {
        output.withLock { output in
            output.log.append("command-process-output: \(command.name): \(ByteString(data).bytes.asReadableString().debugDescription)")
        }
    }
    func commandProcessFinished(_ command: Command, process: ProcessHandle, result: CommandExtendedResult) {
        output.withLock { output in
            output.log.append("command-process-finished: \(command.name)")
        }
    }
    func determinedRuleNeedsToRun(_ rule: BuildKey, reason: RuleRunReason, inputRule: BuildKey?) {
        output.withLock { output in
            output.log.append("determined-rule-needs-to-run: \(rule.description)")
        }
    }
    func cycleDetected(rules: [BuildKey]) {
        output.withLock { output in
            output.log.append("cycle-detected: \(rules.map{ $0.key })")
        }
    }
    func commandCannotBuildOutputDueToMissingInputs(_ command: Command, output: BuildKey, inputs: [BuildKey]) {
        self.output.withLock { outputBox in
            let msg = "commandCannotBuildOutputDueToMissingInputs: \(command.name) \(output.key) \(inputs.map { $0.key })"
            outputBox.log.append(msg)
            outputBox.errors.append(msg)
        }
    }
    func cannotBuildNodeDueToMultipleProducers(output: BuildKey, commands: [Command]) {
        self.output.withLock { outputBox in
            let msg = "cannotBuildNodeDueToMultipleProducers: \(output.key) \(commands.map { $0.name })"
            outputBox.log.append(msg)
            outputBox.errors.append(msg)
        }
    }

    func shouldResolveCycle(rules: [BuildKey], candidate: BuildKey, action: CycleAction) -> Bool {
        output.withLock { output in
            output.log.append("should-resolve-cycle: \(rules.map{ $0.key })")
        }
        return false;
    }
}

/// A minimal, no-op `BuildSystemDelegate`, enough to load a description and run a
/// graph of `phony` commands. Unlike `LoggingDelegate` it records only errors, so
/// it adds nothing measurable to a build of tens of thousands of commands.
fileprivate final class BenchmarkDelegate: BuildSystemDelegate {
    var fs: (any SWBLLBuild.FileSystem)? { nil }

    private let _errors = SWBMutex<[String]>([])

    var errors: [String] { _errors.withLock { $0 } }

    func lookupTool(_ name: String) -> (any Tool)? { nil }
    func hadCommandFailure() {}
    func handleDiagnostic(_ diagnostic: Diagnostic) {
        _errors.withLock { $0.append("\(diagnostic.kind): \(diagnostic.message)") }
    }
    func commandStatusChanged(_ command: Command, kind: CommandStatusKind) {}
    func commandPreparing(_ command: Command) {}
    func commandStarted(_ command: Command) {}
    func shouldCommandStart(_ command: Command) -> Bool { true }
    func commandFinished(_ command: Command, result: CommandResult) {}
    func commandHadError(_ command: Command, message: String) {
        _errors.withLock { $0.append("command-had-error: \(command.name): \(message)") }
    }
    func commandHadNote(_ command: Command, message: String) {}
    func commandHadWarning(_ command: Command, message: String) {}
    func commandCannotBuildOutputDueToMissingInputs(_ command: Command, output: BuildKey, inputs: [BuildKey]) {
        _errors.withLock { $0.append("missing-inputs: \(command.name)") }
    }
    func cannotBuildNodeDueToMultipleProducers(output: BuildKey, commands: [Command]) {
        _errors.withLock { $0.append("multiple-producers: \(output.key)") }
    }
    func commandProcessStarted(_ command: Command, process: ProcessHandle) {}
    func commandProcessHadError(_ command: Command, process: ProcessHandle, message: String) {}
    func commandProcessHadOutput(_ command: Command, process: ProcessHandle, data: [UInt8]) {}
    func commandProcessFinished(_ command: Command, process: ProcessHandle, result: CommandExtendedResult) {}
    func cycleDetected(rules: [BuildKey]) {}
    func shouldResolveCycle(rules: [BuildKey], candidate: BuildKey, action: CycleAction) -> Bool { false }
}

@Suite fileprivate struct LLBuildTests {
    @Test(.requireLLBuild(apiVersion: 15)) func basics() throws {
        // Test basics of executing an in-memory build instance.
        let fs = PseudoFS()

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        // FIXME: Should be able to claim we are our own client.
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "\n"
        manifest <<< "commands:\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: phony\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        // Create a build.
        let delegate = LoggingDelegate(fs: fs)
        let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

        // Build the default target.
        #expect(buildSystem.build())

        #expect(delegate.log == [
                "determined-rule-needs-to-run: <BuildKey.Target name=>",
                "determined-rule-needs-to-run: <BuildKey.Node path=<all>>",
                "command-status-changed: <all>, to: isScanning",
                "determined-rule-needs-to-run: <BuildKey.Command name=<all>>",
                "command-preparing: <all>",
                "should-command-start: <all>",
                "command-started: <all>",
                "command-finished: <all>",
                "command-status-changed: <all>, to: isComplete",
            ])

        // Ensure coverage of a couple random things we can't test directly.
        #expect(Diagnostic.Kind.note.description == "note")
        #expect(Diagnostic.Kind.warning.description == "warning")
        #expect(Diagnostic.Kind.error.description == "error")
    }

    @Test func fileErrors() throws {
        // Test handling of a manifest file error.
        let fs = PseudoFS()

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: not-our-version\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "missing-targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        do {
            let delegate = LoggingDelegate(fs: fs)
            let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

            // Build the default target.
            #expect(!buildSystem.build())

            #expect(delegate.log == [
                "error: unable to configure client",
                "error: unable to load build file"])
        }

        // Check reading a non-existing path.
        do {
            let bogusPath = Path.root.join("bogus")
            let delegate = LoggingDelegate(fs: fs)
            let buildSystem = BuildSystem(buildFile: bogusPath, delegate: delegate)

            // Build the default target.
            #expect(!buildSystem.build())

            #expect(delegate.log == [
                "error: unable to open '\(bogusPath.str)'",
                "error: unable to load build file"])
        }
    }

    @Test(.requireProcessSpawning) func unexpectedErrors() throws {

        // Test handling of errors in unexpected situations (just that we don't crash).
        let fs = PseudoFS()

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "commands:\n"
        // Test a non-UTF8 name.
        manifest <<< "  \"" <<< [0xFF, 0xFF] <<< "\":\n"
        manifest <<< "    tool: shell\n"
        // Test a non-UTF8 description.
        manifest <<< "    description: \"" <<< [0xFF, 0xFF] <<< "\"\n"
        manifest <<< "    args: [\"/usr/bin/true\"]\n"
        manifest <<< "    outputs: [\"<foo>\"]\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: shell\n"
        manifest <<< "    args: [\"/usr/bin/true\"]\n"
        manifest <<< "    inputs: [\"<foo>\", \"relative-path\"]\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        do {
            let delegate = LoggingDelegate(fs: fs)
            let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

            // Build the default target.
            #expect(!buildSystem.build())

            #expect(delegate.log.filter({ $0.hasPrefix("command-process-started") }) == [
                "command-process-started: �� -- ��"])
            #expect(delegate.errors == [
                "commandCannotBuildOutputDueToMissingInputs: <all> <all> [\"relative-path\"]"])
        }
    }

    /// Check that the we can control the subprocess environment
    @Test(.requireProcessSpawning) func subprocessEnvironment() throws {
        let fs = PseudoFS()

        let printenv: String
        let literalNewline: String
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            printenv = try String(decoding: JSONEncoder().encode(["cmd", "/c", "set"]), as: UTF8.self)
            literalNewline = "\\r\\n"
        } else {
            printenv = try String(decoding: JSONEncoder().encode(["/usr/bin/env"]), as: UTF8.self)
            literalNewline = "\\n"
        }

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "commands:\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: shell\n"
        manifest <<< "    args: \(printenv)\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        do {
            let delegate = LoggingDelegate(fs: fs)
            let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate, environment: [
                    "ENV_KEY": "ENV_VALUE"])

            // Build the default target.
            #expect(buildSystem.build())

            // We expect a single output event, with the total environment.
            let outputEvents = delegate.log.filter{ $0.hasPrefix("command-process-output") }
            #expect(outputEvents.count > 0)
            XCTAssertMatch(outputEvents, [.and(.contains("command-process-output: <all>:"), .contains("ENV_KEY=ENV_VALUE\(literalNewline)"))])
        }
    }

    @Test(.requireProcessSpawning, .requireLLBuild(apiVersion: 15)) func processHandling() throws {
        class Delegate: LoggingDelegate {
            var firstCommand: Command? = nil
            // Technically, this isn't legit we shouldn't store these. However, it should work for our test.
            var commandMap = [Command: String]()
            var processMap = [ProcessHandle: String]()

            override func commandStarted(_ command: Command) {
                commandMap[command] = command.name
                if firstCommand == nil {
                    firstCommand = command
                    #expect(firstCommand == firstCommand)
                    #expect(firstCommand?.name == Path.root.join("good.txt").str)
                    #expect(firstCommand?.description == "GOOD")
                } else {
                    #expect(firstCommand != command)
                }
                super.commandStarted(command)
            }

            override func commandProcessStarted(_ command: Command, process: ProcessHandle) {
                #expect(process == process)
                processMap[process] = ""
                super.commandProcessStarted(command, process: process)
            }
        }

        let fs = PseudoFS()

        let echo: String
        let literalNewline: String
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            echo = try String(decoding: JSONEncoder().encode(["cmd", "/c", "echo good"]), as: UTF8.self)
            literalNewline = "\\r\\n"
        } else {
            echo = try String(decoding: JSONEncoder().encode(["/bin/echo", "good"]), as: UTF8.self)
            literalNewline = "\\n"
        }

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "commands:\n"
        manifest <<< "  \"\(Path.root.join("good.txt").str.escapedForJSON)\":\n"
        manifest <<< "    tool: shell\n"
        manifest <<< "    inputs: []\n"
        manifest <<< "    outputs: [\"\(Path.root.join("good.txt").str.escapedForJSON)\"]\n"
        manifest <<< "    description: GOOD\n"
        manifest <<< "    args: \(echo)\n"
        manifest <<< "  \"\(Path.root.join("fail.txt").str.escapedForJSON)\":\n"
        manifest <<< "    tool: shell\n"
        manifest <<< "    description: FAIL\n"
        manifest <<< "    inputs: [\"\(Path.root.join("good.txt").str.escapedForJSON)\"]\n"
        manifest <<< "    outputs: [\"\(Path.root.join("fail.txt").str.escapedForJSON)\"]\n"
        manifest <<< "    args: [\"/bin/does-not-exist\"]\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: phony\n"
        manifest <<< "    inputs: [\"\(Path.root.join("fail.txt").str.escapedForJSON)\"]\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        // Create a build.
        let delegate = Delegate(fs: fs, ignoreStatusChanges: true)
        let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)
        delegate.buildSystem = buildSystem

        // Build the default target.
        #expect(!buildSystem.build())

        var gen = delegate.log.makeIterator()
        #expect(gen.next() == "determined-rule-needs-to-run: <BuildKey.Target name=>")
        #expect(gen.next() == "determined-rule-needs-to-run: <BuildKey.Node path=<all>>")
        #expect(gen.next() == "determined-rule-needs-to-run: <BuildKey.Command name=<all>>")
        #expect(gen.next() == "command-preparing: <all>")
        #expect(gen.next() == "determined-rule-needs-to-run: <BuildKey.Node path=\(Path.root.join("fail.txt").str)>")
        #expect(gen.next() == "determined-rule-needs-to-run: <BuildKey.Command name=\(Path.root.join("fail.txt").str)>")
        #expect(gen.next() == "command-preparing: \(Path.root.join("fail.txt").str)")
        #expect(gen.next() == "determined-rule-needs-to-run: <BuildKey.Node path=\(Path.root.join("good.txt").str)>")
        #expect(gen.next() == "determined-rule-needs-to-run: <BuildKey.Command name=\(Path.root.join("good.txt").str)>")
        #expect(gen.next() == "command-preparing: \(Path.root.join("good.txt").str)")
        #expect(gen.next() == "should-command-start: \(Path.root.join("good.txt").str)")
        #expect(gen.next() == "command-started: \(Path.root.join("good.txt").str)")
        #expect(gen.next() == "command-process-started: \(Path.root.join("good.txt").str) -- GOOD")
        #expect(gen.next() == "command-process-output: \(Path.root.join("good.txt").str): \"good\(literalNewline)\"")
        #expect(gen.next() == "command-process-finished: \(Path.root.join("good.txt").str)")
        #expect(gen.next() == "command-finished: \(Path.root.join("good.txt").str)")
        #expect(gen.next() == "should-command-start: \(Path.root.join("fail.txt").str)")
        #expect(gen.next() == "command-started: \(Path.root.join("fail.txt").str)")
        #expect(gen.next() == "command-process-started: \(Path.root.join("fail.txt").str) -- FAIL")
        #expect(gen.next()?.contains("command-process-error: unable to spawn process") ?? false)
        #expect(gen.next() == "command-process-finished: \(Path.root.join("fail.txt").str)")
        #expect(gen.next() == "command-finished: \(Path.root.join("fail.txt").str)")
        #expect(gen.next() == "had-command-failure")
        #expect(gen.map({$0}) == [])
    }

    @Test(.requireProcessSpawning) func fileSystemHandling() throws {
        // Test basic behavior of the file system.
        let fs = PseudoFS()

        let nullCommand: String
        if try ProcessInfo.processInfo.hostOperatingSystem() == .windows {
            nullCommand = try String(decoding: JSONEncoder().encode(["cmd"]), as: UTF8.self)
        } else {
            nullCommand = try String(decoding: JSONEncoder().encode(["/usr/bin/true"]), as: UTF8.self)
        }

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "commands:\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: shell\n"
        manifest <<< "    args: \(nullCommand)\n"
        manifest <<< "    inputs: [\"\(Path.root.join("subdir").str.escapedForJSON)\", \"\(Path.root.join("input.txt").str.escapedForJSON)\"]\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)
        try fs.createDirectory(Path.root.join("subdir"))

        // Check the build.
        do {
            let delegate = LoggingDelegate(fs: fs)
            let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

            // Build the default target.
            #expect(!buildSystem.build())

            // Verify the input shows as missing.
            #expect([] != delegate.log.filter({
                $0 == "commandCannotBuildOutputDueToMissingInputs: <all> <all> [\"\(Path.root.join("input.txt").str.escapedForJSON)\"]"
                    }), "missing expected error in log: \(delegate.log)")
        }

        // Now write the file, and rebuild.
        try fs.write(Path.root.join("input.txt"), contents: [0])

        // Check the build.
        do {
            let delegate = LoggingDelegate(fs: fs)
            let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

            // Build the default target.
            #expect(buildSystem.build())

            // Verify all is good.
            #expect([] == delegate.log.filter({ $0.contains("error") }))
        }
    }

    @Test func customToolHandling() throws {
        struct Static {
            static let outputPath = Path.root.join("output.txt")
        }

        // FIXME: It is rather annoying that we have to plumb so much context through. We should give the various methods access to some kind of object they can recover it from.
        class WriteCommand: ExternalCommand {
            let delegate: Delegate

            init(delegate: Delegate) {
                self.delegate = delegate
            }

            func getSignature(_ command: Command) -> [UInt8] {
                return []
            }

            func execute(_ command: Command, _ commandInterface: BuildSystemCommandInterface) -> Bool {
                delegate.append(log: "write-command: execute")
                do {
                    try delegate.fsProxy.write(Static.outputPath, contents: [])
                    return true
                } catch {
                    return false
                }
            }
        }
        class WriteTool: Tool {
            let delegate: Delegate

            init(delegate: Delegate) {
                self.delegate = delegate
            }

            func createCommand(_ name: String) -> (any ExternalCommand)? {
                return WriteCommand(delegate: delegate)
            }
        }
        class Delegate: LoggingDelegate {

            override func lookupTool(_ name: String) -> (any Tool)? {
                if name == "write-tool" {
                    return WriteTool(delegate: self)
                }
                return nil
            }
        }

        let fs = PseudoFS()

        let escapedOutputPath = Static.outputPath.str.replacingOccurrences(of: #"\"#, with: #"\\"#)

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "commands:\n"
        manifest <<< "  \"\(escapedOutputPath)\":\n"
        manifest <<< "    tool: write-tool\n"
        manifest <<< "    outputs: [\"\(escapedOutputPath)\"]\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: phony\n"
        manifest <<< "    inputs: [\"\(escapedOutputPath)\"]\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        // Check the build.
        let delegate = Delegate(fs: fs)
        let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

        // Build the default target.
        #expect(!fs.exists(Path.root.join("output.txt")))
        #expect(buildSystem.build())
        #expect(fs.exists(Path.root.join("output.txt")))

        #expect(delegate.log.contains("write-command: execute"))
    }

    @Test(.requireLLBuild(apiVersion: 15)) func commandSkipping() throws {
        let fs = PseudoFS()

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "\n"
        manifest <<< "commands:\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: phony\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        // Configure the delegate
        class Delegate: LoggingDelegate {
            override func shouldCommandStart(_ command: Command) -> Bool {
                let shouldStart = super.shouldCommandStart(command)
                #expect(shouldStart)
                return false
            }
        }

        let delegate = Delegate(fs: fs)

        // Create a build.
        let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

        // Build the default target.
        #expect(buildSystem.build())

        #expect(delegate.log == [
            "determined-rule-needs-to-run: <BuildKey.Target name=>",
            "determined-rule-needs-to-run: <BuildKey.Node path=<all>>",
            "command-status-changed: <all>, to: isScanning",
            "determined-rule-needs-to-run: <BuildKey.Command name=<all>>",
            "command-preparing: <all>",
            "should-command-start: <all>",
            "command-finished: <all>",
            "command-status-changed: <all>, to: isComplete",
            ])
    }

    @Test(.requireLLBuild(apiVersion: 15)) func cycle() throws {
        let fs = PseudoFS()

        // Write the test manifest.
        let manifest = OutputByteStream()
        manifest <<< "client:\n"
        manifest <<< "  name: basic\n"
        manifest <<< "  version: 0\n"
        manifest <<< "\n"
        manifest <<< "targets:\n"
        manifest <<< "  \"\": [\"<all>\"]\n"
        manifest <<< "\n"
        manifest <<< "commands:\n"
        manifest <<< "  \"foo\":\n"
        manifest <<< "    tool: phony\n"
        manifest <<< "    inputs: [\"<all>\"]\n"
        manifest <<< "    outputs: [\"foo\"]\n"
        manifest <<< "  \"<all>\":\n"
        manifest <<< "    tool: phony\n"
        manifest <<< "    inputs: [\"foo\"]\n"
        manifest <<< "    outputs: [\"<all>\"]\n"

        // Write the manifest to disk.
        let manifestPath = Path.root.join("build.xcbuild")
        try fs.write(manifestPath, contents: manifest.bytes)

        // Configure the delegate
        class Delegate: LoggingDelegate {
            override func shouldCommandStart(_ command: Command) -> Bool {
                assert(super.shouldCommandStart(command))
                return false
            }
        }

        let delegate = Delegate(fs: fs)

        // Create a build.
        let buildSystem = BuildSystem(buildFile: manifestPath, delegate: delegate)

        // Build the default target.
        #expect(!buildSystem.build())

        #expect(delegate.log == [
            "determined-rule-needs-to-run: <BuildKey.Target name=>",
            "determined-rule-needs-to-run: <BuildKey.Node path=<all>>",
            "command-status-changed: <all>, to: isScanning",
            "determined-rule-needs-to-run: <BuildKey.Command name=<all>>",
            "command-preparing: <all>",
            "determined-rule-needs-to-run: <BuildKey.Node path=foo>",
            "command-status-changed: foo, to: isScanning",
            "determined-rule-needs-to-run: <BuildKey.Command name=foo>",
            "command-preparing: foo",
            "cycle-detected: [\"\", \"<all>\", \"<all>\", \"foo\", \"foo\", \"<all>\"]",
            ])
    }

    // MARK: In-memory descriptions

    /// Build a valid llbuild manifest of `commandCount` `phony` commands, each
    /// producing a distinct virtual node, plus an `<all>` command depending on all of
    /// them. Only virtual (angle-bracketed) nodes are used, so llbuild performs no
    /// filesystem `stat`s and the measurement isolates description loading from
    /// unrelated file access.
    private func makeManifest(commandCount: Int) -> ByteString {
        let stream = OutputByteStream()
        stream <<< "client:\n"
        stream <<< "  name: basic\n"
        stream <<< "  version: 0\n"
        stream <<< "\n"
        stream <<< "targets:\n"
        stream <<< "  \"\": [\"<all>\"]\n"
        stream <<< "\n"
        stream <<< "commands:\n"
        for i in 0..<commandCount {
            stream <<< "  \"<node-\(i)>\":\n"
            stream <<< "    tool: phony\n"
            stream <<< "    inputs: []\n"
            stream <<< "    outputs: [\"<node-\(i)>\"]\n"
        }
        stream <<< "  \"<all>\":\n"
        stream <<< "    tool: phony\n"
        stream <<< "    inputs: ["
        stream <<< (0..<commandCount).map { "\"<node-\($0)>\"" }.joined(separator: ", ")
        stream <<< "]\n"
        stream <<< "    outputs: [\"<all>\"]\n"
        return stream.bytes
    }

    /// Load and build a manifest from disk once, returning the elapsed time.
    private func timeYAMLBuild(buildFile: Path) -> (duration: Duration, ok: Bool, errors: [String]) {
        let delegate = BenchmarkDelegate()
        let clock = SuspendingClock()
        var ok = false
        let duration = clock.measure {
            let buildSystem = BuildSystem(buildFile: buildFile.str, databaseFile: "", delegate: delegate)
            ok = buildSystem.build()
        }
        return (duration, ok, delegate.errors)
    }

    /// Construct the same graph `makeManifest` describes, but in memory via the
    /// `BuildDescriptionBuilder` bindings, then build it. Returns the construction
    /// time (the FFI-driven graph build) separately from the execution time.
    private func timeInMemoryBuild(commandCount: Int) -> (construct: Duration, build: Duration, ok: Bool, errors: [String]) {
        let delegate = BenchmarkDelegate()
        let clock = SuspendingClock()
        let buildSystem = BuildSystem(description: .inMemory(originName: "<in-memory>") { builder in
            builder.addTarget("", nodes: ["<all>"])
            for i in 0..<commandCount {
                guard let cmd = builder.beginCommand(name: "<node-\(i)>", tool: "phony") else { return false }
                builder.setCommandInputs(cmd, nodes: [])
                builder.setCommandOutputs(cmd, nodes: ["<node-\(i)>"])
                builder.finishCommand(name: "<node-\(i)>", cmd)
            }
            guard let all = builder.beginCommand(name: "<all>", tool: "phony") else { return false }
            builder.setCommandInputs(all, nodes: (0..<commandCount).map { "<node-\($0)>" })
            builder.setCommandOutputs(all, nodes: ["<all>"])
            builder.finishCommand(name: "<all>", all)
            return true
        }, databaseFile: "", delegate: delegate)
        var initOK = false
        let construct = clock.measure {
            initOK = buildSystem.initialize()
        }
        var buildOK = false
        let build = clock.measure { buildOK = buildSystem.build() }
        return (construct, build, initOK && buildOK, delegate.errors)
    }

    /// Correctness: a description built entirely in memory via the bindings loads and
    /// builds successfully with no diagnostics.
    @Test(.requireLLBuild(apiVersion: 15)) func inMemoryDescriptionBuild() throws {
        let r = timeInMemoryBuild(commandCount: 100)
        #expect(r.ok, "in-memory build failed: \(r.errors)")
        #expect(r.errors.isEmpty, "in-memory build had errors: \(r.errors)")
    }

    /// Compare loading the graph from YAML (read + parse + build) against
    /// constructing it in memory via the bindings (FFI construction + build). The
    /// delta is the serialize/parse cost the in-memory path removes, net of the FFI
    /// construction cost it adds.
    @Test(.performance, .requireLLBuild(apiVersion: 15)) func inMemoryVsYAMLConstruction() throws {
        let commandCount = 30000
        let iterations = 8
        let warmup = 2
        let manifest = makeManifest(commandCount: commandCount)

        try withTemporaryDirectory { (tmpDir: Path) in
            let diskManifestPath = tmpDir.join("manifest.json")
            try localFS.write(diskManifestPath, contents: manifest)

            for _ in 0..<warmup {
                _ = timeYAMLBuild(buildFile: diskManifestPath)
                _ = timeInMemoryBuild(commandCount: commandCount)
            }

            var yamlBest = Duration.seconds(Int.max)
            var memBest = Duration.seconds(Int.max)
            var memConstructBest = Duration.seconds(Int.max)
            for _ in 0..<iterations {
                let y = timeYAMLBuild(buildFile: diskManifestPath)
                #expect(y.ok, "YAML build failed: \(y.errors)")
                yamlBest = min(yamlBest, y.duration)

                let m = timeInMemoryBuild(commandCount: commandCount)
                #expect(m.ok, "in-memory build failed: \(m.errors)")
                #expect(m.errors.isEmpty, "in-memory build had errors: \(m.errors)")
                memBest = min(memBest, m.construct + m.build)
                memConstructBest = min(memConstructBest, m.construct)
            }
            print("[in-memory-vs-yaml] YAML load+build best=\(yamlBest.milliseconds)ms; in-memory construct+build best=\(memBest.milliseconds)ms (construct-only=\(memConstructBest.milliseconds)ms) (\(commandCount) commands, \(manifest.count) bytes)")
        }
    }
}

fileprivate extension Duration {
    /// Milliseconds as a Double, for reporting.
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}

fileprivate extension BuildSystem {
    convenience init(buildFile: Path, delegate: any BuildSystemDelegate, environment: [String: String]? = nil) {
        self.init(buildFile: buildFile.str, databaseFile: "", delegate: delegate, environment: environment)
    }
}
