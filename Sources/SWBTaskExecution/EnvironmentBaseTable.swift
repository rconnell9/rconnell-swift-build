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
    /// it, comparing the names in place instead -- and equal names are usually the
    /// same interned string, which makes that a pointer comparison rather than a
    /// walk over the bytes. Environments are registered in task order, which groups
    /// them by target, and commands within a target nearly always share a key list,
    /// so this hits for most of a large build's environments.
    private var lastRegistered: (keys: [String], index: Int)?

    package init() {}

    /// Build a table over all of a build's environments, one per command.
    package init(environments: some Sequence<[(String, String)]>) {
        for bindings in environments {
            _ = register(bindings)
        }
        nameSharedBases()
    }

    /// Build a table over all of a build's environments, one per command, and
    /// resolve each one's encoding in the same pass.
    ///
    /// Preferred over ``init(environments:)`` plus ``encoding(for:)`` per command.
    /// Resolving an encoding on its own has to find the environment's candidate by
    /// its keys, and that lookup hashes every variable name; doing it a second time
    /// per command costs more than everything else building the table does. Here
    /// each environment's candidate is simply remembered from when it was
    /// registered.
    ///
    /// The returned encodings are in the order the environments were given.
    package static func build(environments: [[(String, String)]]) -> (table: EnvironmentBaseTable, encodings: [EnvironmentEncoding]) {
        var table = EnvironmentBaseTable()
        var candidateIndices: [Int?] = []
        candidateIndices.reserveCapacity(environments.count)
        for bindings in environments {
            candidateIndices.append(table.register(bindings))
        }
        table.nameSharedBases()

        let encodings = zip(environments, candidateIndices).map { bindings, candidateIndex -> EnvironmentEncoding in
            guard let candidateIndex, let name = table.candidates[candidateIndex].name else {
                return .inline
            }
            return .useBase(base: name, overrides: table.computeOverrides(in: bindings, relativeTo: table.candidates[candidateIndex].bindings))
        }
        return (table, encodings)
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        candidates.lazy.compactMap { candidate in candidate.name.map { ($0, candidate.bindings) } }
    }

    package func encoding(for bindings: [(String, String)]) -> EnvironmentEncoding {
        guard let candidate = candidate(forKeysOf: bindings), let name = candidate.name else {
            return .inline
        }
        return .useBase(base: name, overrides: computeOverrides(in: bindings, relativeTo: candidate.bindings))
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

    private func candidateIndex(forKeysOf bindings: [(String, String)]) -> Int? {
        candidateIndexByKeys[bindings.map { $0.0 }]
    }

    private func candidate(forKeysOf bindings: [(String, String)]) -> Candidate? {
        candidateIndex(forKeysOf: bindings).map { candidates[$0] }
    }

    private func computeOverrides(in bindings: [(String, String)], relativeTo base: [(String, String)]) -> [(String, String)] {
        var overrides: [(String, String)] = []
        for index in bindings.indices where bindings[index].1 != base[index].1 {
            overrides.append(bindings[index])
        }
        return overrides
    }
}

/// A command's environment together with the already-made decision of how to hand
/// it to llbuild.
///
/// Exists so a command can be emitted without the emitter having to consult the
/// table: resolving an encoding there means finding the environment's candidate by
/// its keys, which hashes every variable name. See
/// ``EnvironmentBaseTable/build(environments:)``, which resolves every command's
/// encoding without that lookup.
package struct ResolvedEnvironment: Sendable {
    package let bindings: [(String, String)]
    package let encoding: EnvironmentEncoding

    package init(bindings: [(String, String)], encoding: EnvironmentEncoding) {
        self.bindings = bindings
        self.encoding = encoding
    }
}
