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

/// A minimal, no-op `BuildSystemDelegate`, enough to load a description and run a
/// graph of `phony` commands.
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

/// What handing llbuild a description in memory costs relative to writing a
/// manifest and having llbuild parse it back — the two ends of
/// `useInMemoryLLBuildDescription`.
@Suite(.performance)
fileprivate struct InMemoryDescriptionPerfTests {
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
    @Test(.requireLLBuild(apiVersion: 15))
    func inMemoryDescriptionBuild() async throws {
        let r = timeInMemoryBuild(commandCount: 100)
        #expect(r.ok, "in-memory build failed: \(r.errors)")
        #expect(r.errors.isEmpty, "in-memory build had errors: \(r.errors)")
    }

    /// Compare loading the graph from YAML (read + parse + build) against
    /// constructing it in memory via the bindings (FFI construction + build). The
    /// delta is the serialize/parse cost the in-memory path removes, net of the FFI
    /// construction cost it adds.
    @Test(.requireLLBuild(apiVersion: 15))
    func inMemoryVsYAMLConstruction() async throws {
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
