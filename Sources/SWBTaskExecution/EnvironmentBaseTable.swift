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
package enum EnvironmentFactoring: Equatable {

    /// Send the environment whole, as the command's own `env`.
    case inline

    /// Point the command at the shared environment base named `base`, sending only
    /// `overrides`
    case useBase(base: String, overrides: [(String, String)])

    package static func == (lhs: EnvironmentFactoring, rhs: EnvironmentFactoring) -> Bool {
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

/// Factors the bulk of shared environment variables out of inidivudal commands
package struct EnvironmentBaseTable: Sendable {

    private struct Candidate: Sendable {
        let bindings: [(String, String)]
        var name: String?
        let unfactorable: Bool
        var references: Int
    }

    private static let minimumCommandsToShareABase = 2

    private var candidates: [Candidate] = []

    private var candidateIndexByKeys: [[String]: Int] = [:]

    package init() {}

    /// Build a table over all of a build's environments.
    package init(environments: some Sequence<[(String, String)]>) {
        for bindings in environments {
            register(bindings)
        }
        nameSharedBases()
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        candidates.lazy.compactMap { candidate in candidate.name.map { ($0, candidate.bindings) } }
    }

    package func factoring(for bindings: [(String, String)]) -> EnvironmentFactoring {
        guard let candidate = candidate(forKeysOf: bindings), let name = candidate.name else { return .inline
        }
        return .useBase(base: name, overrides: computeOverrides(in: bindings, relativeTo: candidate.bindings))
    }

    private mutating func register(_ bindings: [(String, String)]) {
        guard !bindings.isEmpty else { return }

        if let index = candidateIndex(forKeysOf: bindings) {
            candidates[index].references += 1
            return
        }

        let unfactorable = Set(bindings.lazy.map { $0.0 }).count != bindings.count
        candidates.append(Candidate(bindings: bindings, name: nil, unfactorable: unfactorable, references: 1))
        candidateIndexByKeys[bindings.map { $0.0 }] = candidates.count - 1
    }

    private mutating func nameSharedBases() {
        var declared = 0
        for index in candidates.indices where !candidates[index].unfactorable && candidates[index].references >= Self.minimumCommandsToShareABase {
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
