//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

package import SWBCore
import SWBUtil

/// How a single command's environment should be handed to llbuild
package enum EnvironmentEncoding: Equatable {

    /// Send the environment whole, as the command's own `env`.
    case inline

    /// Point the command at the shared environment base named `base`, sending only
    /// `overrides`
    case useBase(base: String, overrides: [(String, String)])

    package static func == (lhs: EnvironmentEncoding, rhs: EnvironmentEncoding) -> Bool {
        switch (lhs, rhs) {
        case (.inline, .inline):
            return true
        case (.useBase(let lBase, let lOverrides), .useBase(let rBase, let rOverrides)):
            return lBase == rBase && lOverrides.elementsEqual(rOverrides, by: ==)
        case (.inline, _), (.useBase, _):
            return false
        }
    }
}

/// Shares the bulk of command environments, so variables many commands have in
/// common are declared once rather than repeated
package struct EnvironmentBaseTable: Sendable {

    private struct Candidate: Sendable {
        let bindings: [(String, String)]
        var name: String?
        let unshareable: Bool
        var references: Int
    }

    private static let minimumCommandsToShareABase = 2

    private var candidates: [Candidate] = []

    private var candidateIndexByKeys: [[String]: Int] = [:]

    /// The candidate the previous registration matched, consulted before
    /// ``candidateIndexByKeys``.
    ///
    /// Worth a special case because a hit skips building the key list and hashing
    /// it, comparing the names in place instead. Environments are registered in task
    /// order, which groups them by target, and commands within a target nearly
    /// always share a key list, so this hits for most of a large build's
    /// environments.
    private var lastRegistered: (keys: [String], index: Int)?

    /// The commands that are sent against a base, and what to send for them.
    ///
    /// Commands absent from this are sent whole, which is why ``encoding(for:)``
    /// needs no default of its own.
    private var encodingByTask: [TaskIdentifier: EnvironmentEncoding] = [:]

    package init() {}

    /// Build a table over every command's environment, naming the bases worth
    /// sharing and working out how each command's environment is sent.
    ///
    /// The encodings are settled here rather than when each command is emitted
    /// because finding an environment's base means building and hashing its list of
    /// variable names, and a large build has one thousand-variable environment per
    /// command -- paying that per command costs about as much again as building the
    /// whole table.
    package init(environments: some Sequence<(task: TaskIdentifier, bindings: [(String, String)])>) {
        // Which key lists are shared by enough commands to be worth declaring is not
        // known until they have all been registered, so what registration matched is
        // held onto and the encodings are finished in a second pass. The bindings are
        // not copied -- these hold the same arrays the caller passed.
        var registered: [(task: TaskIdentifier, bindings: [(String, String)], candidate: Int)] = []
        for (task, bindings) in environments {
            if let candidate = register(bindings) {
                registered.append((task, bindings, candidate))
            }
        }
        nameSharedBases()

        for entry in registered {
            guard let name = candidates[entry.candidate].name else { continue }
            encodingByTask[entry.task] = .useBase(base: name, overrides: computeOverrides(in: entry.bindings, relativeTo: candidates[entry.candidate].bindings))
        }
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        candidates.lazy.compactMap { candidate in candidate.name.map { ($0, candidate.bindings) } }
    }

    /// How this command's environment should be sent: against one of
    /// ``declaredBases``, or whole.
    ///
    /// Callers need not agree on how they factor the same build. llbuild hashes a
    /// command's *effective* environment rather than the base and overrides it was
    /// given separately -- see `ShellCommand::getSignature` -- so moving bindings
    /// into a base, or declining to, cannot change a command's signature.
    package func encoding(for task: TaskIdentifier) -> EnvironmentEncoding {
        encodingByTask[task] ?? .inline
    }

    /// Record one command's environment, returning the index of the candidate it
    /// shares its keys with (`nil` for an empty environment, which gets no base).
    private mutating func register(_ bindings: [(String, String)]) -> Int? {
        guard !bindings.isEmpty else { return nil }

        if let lastRegistered, lastRegistered.keys.count == bindings.count,
           zip(lastRegistered.keys, bindings).allSatisfy({ $0 == $1.0 }) {
            candidates[lastRegistered.index].references += 1
            return lastRegistered.index
        }

        let keys = bindings.map { $0.0 }
        let index: Int
        if let existing = candidateIndexByKeys[keys] {
            candidates[existing].references += 1
            index = existing
        } else {
            let unshareable = Set(keys).count != keys.count
            candidates.append(Candidate(bindings: bindings, name: nil, unshareable: unshareable, references: 1))
            index = candidates.count - 1
            candidateIndexByKeys[keys] = index
        }
        lastRegistered = (keys, index)
        return index
    }

    private mutating func nameSharedBases() {
        var declared = 0
        for index in candidates.indices where !candidates[index].unshareable && candidates[index].references >= Self.minimumCommandsToShareABase {
            candidates[index].name = "env-base-\(declared)"
            declared += 1
        }
    }

    private func computeOverrides(in bindings: [(String, String)], relativeTo base: [(String, String)]) -> [(String, String)] {
        var overrides: [(String, String)] = []
        for index in bindings.indices where bindings[index].1 != base[index].1 {
            overrides.append(bindings[index])
        }
        return overrides
    }
}
