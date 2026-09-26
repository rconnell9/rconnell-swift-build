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

package import SWBUtil

/// The small, non-command remainder of the llbuild build graph that Swift Build
/// must persist to drive llbuild directly (via the `BuildDescriptionBuilder`
/// bindings) without re-parsing `manifest.json`.
///
/// The bulk of the graph — the command per task — is *not* stored here: it is
/// reconstructed at load time directly from the `FrozenTaskStore` (each task's
/// tool and attributes derive from its `Task`, and its final input/output node
/// names from the task store's `LLBuildNodeList`). See `emitLLBuildCommand(...)`.
///
/// What remains here is the handful of graph pieces that are products of
/// planning analysis and have no backing `Task`:
///
/// - **`nodes`** — standalone node definitions carrying attributes
///   (`is-mutated`, `content-exclusion-patterns`, `is-command-timestamp`). The
///   underlying `PlannedNode` objects (and the mutation analysis that flags
///   them) are gone at load time, so their attributes must travel here.
/// - **`staleFileRemovalCommands`** — the per-target stale-file-removal commands
///   (`expectedOutputs` + `roots`), which are synthesized during construction
///   rather than corresponding to any task.
/// - **`allRoots`** — the inputs of the synthetic `<all>` root target command
///   (all outputs never consumed as an input).
/// - **`performOwnershipAnalysis`** and **`fileSystemMode`** — the two
///   manifest-level settings that decide how llbuild interprets the graph.
///
/// The single fixed target (`""` → `["<all>"]`) and the absence of a default
/// target are constants and are applied by the driver, not stored.
///
/// This is whole-description metadata: nothing in it is keyed by a task, so it
/// is persisted with the `BuildDescription` (`description.msgpack`) rather than
/// with the per-task tables in the `FrozenTaskStore` (`task-store.msgpack`).
package struct LLBuildGraphSupplement: Sendable {
    /// A standalone node definition with attributes not recoverable from a `Task`.
    package struct Node: Sendable {
        package var name: String
        /// `content-exclusion-patterns` for directory-tree nodes (empty if none).
        package var exclusionPatterns: [String]
        /// The `is-mutated` attribute.
        package var isMutated: Bool
        /// The `is-command-timestamp` attribute (trigger nodes).
        package var isCommandTimestamp: Bool

        package init(name: String, exclusionPatterns: [String] = [], isMutated: Bool = false, isCommandTimestamp: Bool = false) {
            self.name = name
            self.exclusionPatterns = exclusionPatterns
            self.isMutated = isMutated
            self.isCommandTimestamp = isCommandTimestamp
        }
    }

    /// A synthesized per-target stale-file-removal command.
    package struct StaleFileRemoval: Sendable {
        package var name: String
        package var expectedOutputs: [String]
        package var roots: [String]

        package init(name: String, expectedOutputs: [String], roots: [String]) {
            self.name = name
            self.expectedOutputs = expectedOutputs
            self.roots = roots
        }
    }

    package var nodes: [Node] = []
    package var staleFileRemovalCommands: [StaleFileRemoval] = []
    /// Inputs of the synthetic `<all>` root command.
    package var allRoots: [String] = []
    /// Whether llbuild should run ownership analysis when finalizing the
    /// description (mirrors the manifest's `perform-ownership-analysis`).
    package var performOwnershipAnalysis: Bool = false
    /// The file-system comparison mode llbuild must run with (mirrors the
    /// manifest's `file-system`).
    ///
    /// This is not part of the graph, but it has to travel with it: it decides
    /// which parts of a `stat` llbuild records for each output, so a build that
    /// replays this description with the wrong mode considers every output
    /// modified. It is recorded rather than re-read from the current filesystem so
    /// the two paths agree even if the preference changes between builds.
    package var fileSystemMode: FileSystemMode = .fullStat

    package init() {}
}

extension LLBuildGraphSupplement.Node: Serializable {
    package func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(4) {
            serializer.serialize(name)
            serializer.serialize(exclusionPatterns)
            serializer.serialize(isMutated)
            serializer.serialize(isCommandTimestamp)
        }
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(4)
        self.name = try deserializer.deserialize()
        self.exclusionPatterns = try deserializer.deserialize()
        self.isMutated = try deserializer.deserialize()
        self.isCommandTimestamp = try deserializer.deserialize()
    }
}

extension LLBuildGraphSupplement.StaleFileRemoval: Serializable {
    package func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(3) {
            serializer.serialize(name)
            serializer.serialize(expectedOutputs)
            serializer.serialize(roots)
        }
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.name = try deserializer.deserialize()
        self.expectedOutputs = try deserializer.deserialize()
        self.roots = try deserializer.deserialize()
    }
}

extension LLBuildGraphSupplement: Serializable {
    package func serialize<T: Serializer>(to serializer: T) {
        serializer.serializeAggregate(5) {
            serializer.serialize(nodes)
            serializer.serialize(staleFileRemovalCommands)
            serializer.serialize(allRoots)
            serializer.serialize(performOwnershipAnalysis)
            // Recorded in the form the manifest carries, so the two paths cannot
            // drift apart in how they spell the mode.
            serializer.serialize(fileSystemMode.manifestLabel)
        }
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(5)
        self.nodes = try deserializer.deserialize()
        self.staleFileRemovalCommands = try deserializer.deserialize()
        self.allRoots = try deserializer.deserialize()
        self.performOwnershipAnalysis = try deserializer.deserialize()
        let fileSystemModeLabel: String = try deserializer.deserialize()
        guard let fileSystemMode = FileSystemMode(manifestLabel: fileSystemModeLabel) else {
            throw DeserializerError.unexpectedValue("unknown file system mode '\(fileSystemModeLabel)'")
        }
        self.fileSystemMode = fileSystemMode
    }
}
