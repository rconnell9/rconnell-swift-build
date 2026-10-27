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
        var declaredIndex: Int?
        let unshareable: Bool

        /// The commands whose environments share these keys, including the one the
        /// candidate was created for.
        var members: [(task: TaskIdentifier, bindings: [(String, String)])]
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

    /// The base each command's environment is sent against, for the commands that
    /// have one.
    private var baseReferenceByTask: [TaskIdentifier: (index: Int, positions: [Int])] = [:]

    package init() {}

    /// Build a table over all of a build's environments, named by the command each
    /// belongs to.
    ///
    /// The commands are named so that a base can be found by command rather than by
    /// environment. Finding one by environment costs a list of that environment's
    /// variable names and a hash of it, and a large build has one
    /// thousand-variable environment per command, so paying that per command costs
    /// about as much again as building the whole table.
    package init(environments: some Sequence<(task: TaskIdentifier, bindings: [(String, String)])>) {
        for (task, bindings) in environments {
            register(task, bindings)
        }

        // Which key lists are shared by enough commands to be worth declaring is not
        // known until all of them have been registered, so the references are resolved
        // in a second pass.
        nameSharedBases()
        for candidate in candidates {
            guard let index = candidate.declaredIndex else { continue }
            for member in candidate.members {
                baseReferenceByTask[member.task] = (index, differingPositions(in: member.bindings, relativeTo: candidate.bindings))
            }
        }
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        candidates.lazy.compactMap { candidate in candidate.declaredIndex.map { (Self.name(ofBase: $0), candidate.bindings) } }
    }

    /// How this command's environment should be sent.
    ///
    /// Callers need not agree on how they factor the same build. llbuild hashes a
    /// command's *effective* environment rather than the base and overrides it was
    /// given separately -- see `ShellCommand::getSignature` -- so moving bindings
    /// into a base, or declining to, cannot change a command's signature.
    package func encoding(for task: TaskIdentifier, bindings: [(String, String)]) -> EnvironmentEncoding {
        guard let reference = baseReference(for: task) else {
            return .inline
        }
        return .useBase(base: Self.name(ofBase: reference.index), overrides: reference.positions.map { bindings[$0] })
    }

    /// The base for this command's environment, by its position in
    /// ``declaredBases``, and the positions at which the command's environment has a
    /// different value.
    ///
    /// `nil` for a command that has no base, including one the table was not built
    /// over -- whose environment is then sent whole rather than mis-encoded.
    package func baseReference(for task: TaskIdentifier) -> (index: Int, positions: [Int])? {
        baseReferenceByTask[task]
    }

    private static func name(ofBase index: Int) -> String {
        "env-base-\(index)"
    }

    /// Record one command's environment against the candidate it shares its keys
    /// with, creating that candidate if it is the first with those keys.
    ///
    /// An empty environment is dropped -- it gets no base.
    private mutating func register(_ task: TaskIdentifier, _ bindings: [(String, String)]) {
        guard !bindings.isEmpty else { return }

        if let lastRegistered, lastRegistered.keys.count == bindings.count,
           zip(lastRegistered.keys, bindings).allSatisfy({ $0 == $1.0 }) {
            candidates[lastRegistered.index].members.append((task, bindings))
            return
        }

        let keys = bindings.map { $0.0 }
        let index: Int
        if let existing = candidateIndexByKeys[keys] {
            candidates[existing].members.append((task, bindings))
            index = existing
        } else {
            let unshareable = Set(keys).count != keys.count
            candidates.append(Candidate(bindings: bindings, declaredIndex: nil, unshareable: unshareable, members: [(task, bindings)]))
            index = candidates.count - 1
            candidateIndexByKeys[keys] = index
        }
        lastRegistered = (keys, index)
    }

    private mutating func nameSharedBases() {
        var declared = 0
        for index in candidates.indices where !candidates[index].unshareable && candidates[index].members.count >= Self.minimumCommandsToShareABase {
            candidates[index].declaredIndex = declared
            declared += 1
        }
    }

    private func differingPositions(in bindings: [(String, String)], relativeTo base: [(String, String)]) -> [Int] {
        bindings.indices.filter { bindings[$0].1 != base[$0].1 }
    }
}
