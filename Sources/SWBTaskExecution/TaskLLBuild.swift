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

import SWBUtil
import SWBCore
package import SWBLLBuild

/// Drives llbuild's `BuildDescriptionBuilder` (the in-memory C API) directly from
/// a completed `BuildDescription`, bypassing `manifest.json` entirely.
///
/// Every command is reconstructed on the fly from the frozen task store: each
/// `Task` supplies the tool + attributes (see `emitLLBuildCommand`, which the
/// `manifest.json` writer mirrors), the stored `LLBuildNodeList` supplies the
/// final input/output node names (real files + virtual gates), and the
/// `LLBuildGraphSupplement` supplies the handful of non-command graph pieces
/// (standalone node attributes, stale-file-removal commands, the `<all>` root,
/// ownership). No llbuild-shaped artifact is persisted; the task store *is* the
/// artifact.
extension BuildDescription {
    /// Populate `builder` with this description's full llbuild graph.
    ///
    /// Returns `false` if any command could not be created (e.g. an unknown
    /// tool), which aborts in-memory initialization and falls back to parsing
    /// `manifest.json`.
    package func populateLLBuildDescription(builder: SWBLLBuild.BuildDescriptionBuilder) -> Bool {
        let graphSupplement = self.graphSupplement

        // The file-system mode is not part of the graph, but it decides which
        // fields of a `stat` llbuild records for each output. It has to match what
        // the manifest for this same description declares, or a build that switches
        // between the two paths sees every output as modified.
        switch graphSupplement.fileSystemMode {
        case .fullStat:
            builder.setFileSystemMode(.full)
        case .deviceAgnostic:
            builder.setFileSystemMode(.deviceAgnostic)
        case .checksumOnly:
            builder.setFileSystemMode(.checksumOnly)
        }

        // Configure explicitly-declared nodes and their attributes first; node
        // lookup is by name and idempotent, so commands referencing the same
        // nodes below resolve to these configured instances.
        for node in graphSupplement.nodes {
            if !node.exclusionPatterns.isEmpty {
                builder.setNodeAttribute(node: node.name, name: "content-exclusion-patterns", values: node.exclusionPatterns)
            }
            if node.isMutated {
                builder.setNodeAttribute(node: node.name, name: "is-mutated", value: "true")
            }
            if node.isCommandTimestamp {
                builder.setNodeAttribute(node: node.name, name: "is-command-timestamp", value: "true")
            }
        }

        // The single fixed root target.
        builder.addTarget("", nodes: ["<all>"])

        let sink = LLBuildBuilderCommandSink(builder: builder)

        // Factor the shared bulk out of the command environments, exactly as the
        // manifest writer does. Built before any command is emitted, over the same
        // task order the emission walk below uses, because it is the registration
        // order that decides which environment's values each base is declared with.
        var environments: [[(String, String)]] = []
        taskStore.forEachTaskInLLBuildOrder { task, _ in
            if let environment = task.environmentToEmit {
                environments.append(environment.bindings)
            }
        }
        let environmentBases = EnvironmentBaseTable(environments: environments)
        for (name, bindings) in environmentBases.declaredBases {
            sink.declareEnvironmentBase(name, bindings: bindings)
        }

        // One command per task, derived from the task itself + its stored node list,
        // in a deterministic order (see `forEachTaskInLLBuildOrder`).
        var ok = true
        taskStore.forEachTaskInLLBuildOrder { task, nodeList in
            guard ok else { return }
            guard let nodeList else {
                // Every task inserted into the store records a node list; a missing
                // one indicates a malformed store we cannot faithfully replay.
                ok = false
                return
            }
            if !emitLLBuildCommand(task: task, nodeList: nodeList, bypassActualTasks: bypassActualTasks, environmentBases: environmentBases, into: sink) {
                ok = false
            }
        }
        guard ok else { return false }

        // The synthesized per-target stale-file-removal commands.
        for sfr in graphSupplement.staleFileRemovalCommands {
            guard let cmd = builder.beginCommand(name: sfr.name, tool: "stale-file-removal") else {
                return false
            }
            builder.setCommandOutputs(cmd, nodes: [sfr.name])
            builder.setCommandAttribute(cmd, name: "expectedOutputs", values: sfr.expectedOutputs)
            if !sfr.roots.isEmpty {
                builder.setCommandAttribute(cmd, name: "roots", values: sfr.roots)
            }
            builder.finishCommand(name: sfr.name, cmd)
        }

        // The synthetic `<all>` root command.
        guard let allCommand = builder.beginCommand(name: "<all>", tool: "phony") else {
            return false
        }
        if !graphSupplement.allRoots.isEmpty {
            builder.setCommandInputs(allCommand, nodes: graphSupplement.allRoots)
        }
        builder.setCommandOutputs(allCommand, nodes: ["<all>"])
        builder.finishCommand(name: "<all>", allCommand)

        builder.setPerformOwnershipAnalysis(graphSupplement.performOwnershipAnalysis)
        return true
    }
}

/// Records commands into llbuild's in-memory `BuildDescriptionBuilder` (the C
/// API). The only `LLBuildCommandSink` there is; the `manifest.json` writer emits
/// the equivalent JSON itself rather than through the sink protocol.
///
/// Empty input/output lists are skipped rather than sent, matching what the
/// builder expects of an embedder.
final class LLBuildBuilderCommandSink: LLBuildCommandSink {
    private let builder: SWBLLBuild.BuildDescriptionBuilder
    private var name: String = ""
    private var command: SWBLLBuild.Command?

    init(builder: SWBLLBuild.BuildDescriptionBuilder) {
        self.builder = builder
    }

    private var open: SWBLLBuild.Command {
        guard let command else {
            preconditionFailure("no open llbuild command")
        }
        return command
    }

    func beginCommand(name: String, tool: String) -> Bool {
        guard let command = builder.beginCommand(name: name, tool: tool) else {
            return false
        }
        self.name = name
        self.command = command
        return true
    }

    func setInputs(_ nodes: [String]) {
        guard !nodes.isEmpty else { return }
        builder.setCommandInputs(open, nodes: nodes)
    }

    func setOutputs(_ nodes: [String]) {
        guard !nodes.isEmpty else { return }
        builder.setCommandOutputs(open, nodes: nodes)
    }

    func setDescription(_ description: String) {
        builder.setCommandDescription(open, description)
    }

    func setAttribute(_ name: String, _ value: String) {
        builder.setCommandAttribute(open, name: name, value: value)
    }

    func setAttribute(_ name: String, bool value: Bool) {
        builder.setCommandAttribute(open, name: name, value: value ? "true" : "false")
    }

    func setAttribute(_ name: String, values: [String]) {
        builder.setCommandAttribute(open, name: name, values: values)
    }

    func setAttribute(_ name: String, byteValues: [ByteString]) {
        builder.setCommandAttribute(open, name: name, values: byteValues.map { $0.asString })
    }

    func setAttribute(_ name: String, pairs: [(String, String)]) {
        builder.setCommandAttribute(open, name: name, pairs: pairs)
    }

    func declareEnvironmentBase(_ base: String, bindings: [(String, String)]) {
        builder.addEnvironmentBase(base, bindings: bindings)
    }

    func setEnvironmentBase(_ base: String) {
        builder.setCommandEnvironmentBase(open, base: base)
    }

    func finishCommand() {
        builder.finishCommand(name: name, open)
        command = nil
    }
}
