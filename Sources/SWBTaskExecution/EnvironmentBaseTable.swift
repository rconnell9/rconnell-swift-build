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
///
/// `Token` stands for a variable name or value. It need only compare equal exactly
/// when the strings it stands for do, which lets a caller whose environments are
/// already interned factor them without materializing a single string: the only
/// questions the table asks of an environment are "does it declare the same names,
/// in the same order, as one already seen?" and "which of its values differ from
/// its base's?", and an interning arena's handles answer both. That matters at the
/// scale this exists for, because almost none of a large build's bindings are
/// ultimately sent -- WebKit's 4,213 command environments hold about five million
/// bindings between them, and sharing them into bases is exactly what reduces that
/// to a few hundred thousand.
///
/// Strings are therefore produced only where one is really going to be handed over:
/// a declared base's bindings, a command's overrides, and an environment sent
/// inline.
package struct EnvironmentBaseTable<Token: Hashable & Sendable>: Sendable {

    private struct Candidate: Sendable {
        /// Held as tokens, so an environment that defines a key list but whose base
        /// is never declared costs nothing to have kept.
        let bindings: [(Token, Token)]
        var name: String?
        let unshareable: Bool
        var references: Int
    }

    private static var minimumCommandsToShareABase: Int { 2 }

    private let materialize: @Sendable (Token) -> String

    private var candidates: [Candidate] = []

    private var candidateIndexByKeys: [[Token]: Int] = [:]

    /// The candidate the previous registration matched, consulted before
    /// ``candidateIndexByKeys``.
    ///
    /// Worth a special case because a hit skips building the key list and hashing
    /// it, comparing the names in place instead. Environments are registered in task
    /// order, which groups them by target, and commands within a target nearly
    /// always share a key list, so this hits for most of a large build's
    /// environments.
    private var lastRegistered: (keys: [Token], index: Int)?

    package init(materialize: @escaping @Sendable (Token) -> String) {
        self.materialize = materialize
    }

    /// Build a table over all of a build's environments, one per command.
    package init(environments: some Sequence<[(Token, Token)]>, materialize: @escaping @Sendable (Token) -> String) {
        self.init(materialize: materialize)
        for bindings in environments {
            _ = register(bindings)
        }
        nameSharedBases()
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        candidates.compactMap { candidate in
            candidate.name.map { ($0, candidate.bindings.map(materializeBinding)) }
        }
    }

    package func encoding(for bindings: [(Token, Token)]) -> EnvironmentEncoding {
        guard let candidate = candidate(forKeysOf: bindings), let name = candidate.name else {
            return .inline
        }
        return .useBase(base: name, overrides: computeOverrides(in: bindings, relativeTo: candidate.bindings))
    }

    /// Record one command's environment, returning the index of the candidate it
    /// shares its keys with (`nil` for an empty environment, which gets no base).
    private mutating func register(_ bindings: [(Token, Token)]) -> Int? {
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

    private func candidateIndex(forKeysOf bindings: [(Token, Token)]) -> Int? {
        candidateIndexByKeys[bindings.map { $0.0 }]
    }

    private func candidate(forKeysOf bindings: [(Token, Token)]) -> Candidate? {
        candidateIndex(forKeysOf: bindings).map { candidates[$0] }
    }

    private func materializeBinding(_ binding: (Token, Token)) -> (String, String) {
        (materialize(binding.0), materialize(binding.1))
    }

    private func computeOverrides(in bindings: [(Token, Token)], relativeTo base: [(Token, Token)]) -> [(String, String)] {
        var overrides: [(String, String)] = []
        for index in bindings.indices where bindings[index].1 != base[index].1 {
            overrides.append(materializeBinding(bindings[index]))
        }
        return overrides
    }
}

extension EnvironmentBaseTable where Token == String {
    /// A table over environments already held as strings, which need no
    /// materializing.
    package init() {
        self.init(materialize: { $0 })
    }

    /// Build a table over all of a build's environments, one per command.
    package init(environments: some Sequence<[(String, String)]>) {
        self.init(environments: environments, materialize: { $0 })
    }
}

/// The product of factoring a build's environments: the bases to declare, and what
/// each command should send.
package struct EnvironmentFactoring: Sendable {
    /// The bases to declare before any command references one, in the order they
    /// were first needed.
    package let declaredBases: [(name: String, bindings: [(String, String)])]

    /// What each command should send, in the order the environments were given.
    package let environments: [ResolvedEnvironment]
}

extension EnvironmentBaseTable {
    /// Factor a build's environments, resolving what each command sends in the same
    /// pass that builds the table.
    ///
    /// Preferred over ``init(environments:materialize:)`` plus ``encoding(for:)``
    /// per command. Resolving an encoding on its own has to find the environment's
    /// candidate by its keys, and that lookup hashes every variable name; doing it a
    /// second time per command costs more than everything else building the table
    /// does. Here each environment's candidate is simply remembered from when it was
    /// registered.
    ///
    /// Callers need not agree on how they factor the same build. llbuild hashes a
    /// command's *effective* environment rather than the base and overrides it was
    /// given separately -- see `ShellCommand::getSignature` -- so moving bindings
    /// into a base, or declining to, cannot change a command's signature.
    package static func factor(environments: [[(Token, Token)]], materialize: @escaping @Sendable (Token) -> String) -> EnvironmentFactoring {
        var table = EnvironmentBaseTable(materialize: materialize)
        var candidateIndices: [Int?] = []
        candidateIndices.reserveCapacity(environments.count)
        for bindings in environments {
            candidateIndices.append(table.register(bindings))
        }
        table.nameSharedBases()

        let resolved = zip(environments, candidateIndices).map { bindings, candidateIndex -> ResolvedEnvironment in
            guard let candidateIndex, let name = table.candidates[candidateIndex].name else {
                // Sent whole, so this is the one case that pays to materialize an
                // entire environment.
                return ResolvedEnvironment(bindings: bindings.map(table.materializeBinding), base: nil)
            }
            return ResolvedEnvironment(bindings: table.computeOverrides(in: bindings, relativeTo: table.candidates[candidateIndex].bindings), base: name)
        }
        return EnvironmentFactoring(declaredBases: table.declaredBases, environments: resolved)
    }
}

/// What a command sends for its environment, with the decision of how to hand it to
/// llbuild already made.
///
/// Exists so a command can be emitted without the emitter having to consult the
/// table: resolving an encoding there means finding the environment's candidate by
/// its keys, which hashes every variable name. See
/// ``EnvironmentBaseTable/factor(environments:materialize:)``, which resolves every
/// command's environment without that lookup.
package struct ResolvedEnvironment: Sendable {
    /// The bindings to send, which for a command pointed at a base are only those
    /// differing from it.
    package let bindings: [(String, String)]

    /// The base to point the command at, or `nil` to send ``bindings`` as the whole
    /// environment.
    package let base: String?

    package init(bindings: [(String, String)], base: String?) {
        self.bindings = bindings
        self.base = base
    }
}
