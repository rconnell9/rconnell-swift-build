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

/// How a single command's environment should be handed to llbuild
package enum EnvironmentFactoring: Equatable {
    /// Send the environment whole, as the command's own `env`.
    case inline

    /// Point the command at the shared environment base named `base`, sending only
    /// `overrides`.  The bindings whose values differ from it -- as its `env`. An
    /// empty `overrides` means the base *is* the command's environment.
    case useBase(base: String, overrides: [(String, String)])

    // Written out because `overrides` is an array of tuples, which cannot be
    // `Equatable`, so the conformance is not synthesized. The mismatches are
    // spelled out rather than left to a `default`, so that a case added later
    // fails to compile instead of silently comparing unequal to itself.
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

/// Factors the shared bulk out of command environments.
///
/// A build's shell environments are nearly copies of one another: in a large
/// project a few thousand commands share on the order of a hundred distinct *sets*
/// of variable names, differing only in a handful of values. Sending each one
/// whole means handing llbuild the same few hundred names, and most of the same
/// values, thousands of times over -- which on a large project is the great
/// majority of the build manifest's bytes.
///
/// Measured on a WebKit manifest: 450 MiB, of which 82% was command environments.
/// 4,164 commands carried a non-empty environment, 4,047 of those environments
/// distinct, yet there were only 134 distinct key lists among them -- averaging
/// 1,207 variables and 91 KiB each, of which just 7 values differed from the rest
/// of the group. Factoring takes the manifest to 93 MiB.
///
/// Commands are grouped by their exact *ordered* key list. Each group gets a
/// shared base, declared once in the manifest's `env-bases` map, holding the
/// bindings of the first environment registered for that key list; every command
/// in the group then points at the base via `env-base` and sends only the keys
/// whose values differ.
///
/// The ordering requirement is what makes this invisible to the build database:
/// llbuild substitutes an override in place of the base's binding rather than
/// appending it, so a command whose keys are exactly the base's keys ends up with
/// an effective environment identical -- values *and* order -- to the one it would
/// have had unfactored. Command signatures are computed over the effective
/// environment, so factoring changes none of them and an incremental build can
/// cross between a factored and an unfactored description freely.
///
/// The table is built up front from all of a build's environments, in a
/// deterministic order, and is then queried read-only. Which base a given
/// environment lands in therefore does not depend on the order commands happen to
/// be emitted in, which is what keeps the manifest byte-identical across two
/// constructions of the same workspace even though its commands are built in
/// parallel.
package struct EnvironmentBaseTable: Sendable {
    /// A key list that might be worth a shared base, and the environment whose
    /// values would declare it.
    private struct Candidate: Sendable {
        /// The bindings the base would be declared with, in order. Every member of
        /// the group has this same key list, index for index, so computing a
        /// member's overrides is a walk of two arrays rather than a map lookup per
        /// variable.
        let bindings: [(String, String)]

        /// The name to declare the base under, or `nil` where this key list did not
        /// earn one and its members send their environments whole. Assigned once
        /// every environment has been registered; see `nameSharedBases()`.
        var name: String?

        /// Set when this key list cannot be represented as a base at all. See
        /// `register(_:)`.
        let unfactorable: Bool

        /// How many environments registered with this key list.
        var references: Int
    }

    /// A base has to be declared in full somewhere, so a key list only one command
    /// uses costs strictly more factored than inline -- the declaration is the
    /// environment, and the command adds an `env-base` reference on top of it.
    ///
    /// Sharing by two is not just the break-even point but, measured across a range
    /// of real manifests, exactly as good as choosing per group by computed byte
    /// cost: no group that clears this bar fails to pay for itself. Note there is
    /// deliberately no minimum *size* here. The SwiftPM-shaped builds in that set
    /// carry a single variable -- a 1.5 KiB `PATH` -- repeated across every command,
    /// which a rule phrased in terms of variable counts would step right over.
    private static let minimumCommandsToShareABase = 2

    private var candidates: [Candidate] = []

    /// Candidates by hash of the key list. A bucket holds more than one entry only
    /// on hash collision, which the key comparison then resolves.
    private var candidatesByKeysHash: [Int: [Int]] = [:]

    /// An empty table, which factors nothing: every environment is `.inline`.
    package init() {}

    /// Build a table over all of a build's environments.
    ///
    /// `environments` must be in an order that does not vary between two
    /// constructions of the same build, because it decides which environment's
    /// values each base is declared with, and hence what every other member of
    /// its group sends as overrides.
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

    /// How `bindings` should be sent, given the bases this table holds.
    ///
    /// An environment that was never registered -- or one whose key list did not
    /// earn a base -- is sent whole.
    package func factoring(for bindings: [(String, String)]) -> EnvironmentFactoring {
        guard let candidate = candidate(forKeysOf: bindings), let name = candidate.name else { return .inline }
        return .useBase(base: name, overrides: overrides(in: bindings, of: candidate.bindings))
    }

    private mutating func register(_ bindings: [(String, String)]) {
        guard !bindings.isEmpty else { return }
        if let index = candidateIndex(forKeysOf: bindings) {
            candidates[index].references += 1
            return
        }

        // The first environment registered with these keys is the one that would
        // declare the base for the rest.
        //
        // A duplicated key would not survive the round trip -- the base holds one
        // binding per key, and an override substitutes in place rather than
        // repeating -- so such a key list is recorded as unfactorable rather than
        // silently collapsed. Bindings come from a dictionary in practice, so this
        // is a guard rather than a case worth optimizing.
        let unfactorable = Set(bindings.lazy.map { $0.0 }).count != bindings.count
        candidates.append(Candidate(bindings: bindings, name: nil, unfactorable: unfactorable, references: 1))
        candidatesByKeysHash[Self.keysHash(of: bindings), default: []].append(candidates.count - 1)
    }

    /// Name the key lists that earned a base, which is what commits the table to
    /// factoring them. Done in one pass at the end so that the names run
    /// consecutively over the bases actually declared, rather than leaving gaps
    /// where a key list turned out to be used just once.
    private mutating func nameSharedBases() {
        var declared = 0
        for index in candidates.indices where !candidates[index].unfactorable && candidates[index].references >= Self.minimumCommandsToShareABase {
            candidates[index].name = "env-base-\(declared)"
            declared += 1
        }
    }

    private func candidateIndex(forKeysOf bindings: [(String, String)]) -> Int? {
        for index in candidatesByKeysHash[Self.keysHash(of: bindings)] ?? [] where hasSameKeys(candidates[index].bindings, bindings) {
            return index
        }
        return nil
    }

    private func candidate(forKeysOf bindings: [(String, String)]) -> Candidate? {
        candidateIndex(forKeysOf: bindings).map { candidates[$0] }
    }

    private static func keysHash(of bindings: [(String, String)]) -> Int {
        var hasher = Hasher()
        for (key, _) in bindings {
            hasher.combine(key)
        }
        return hasher.finalize()
    }

    private func hasSameKeys(_ lhs: [(String, String)], _ rhs: [(String, String)]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices where lhs[index].0 != rhs[index].0 {
            return false
        }
        return true
    }

    private func overrides(in bindings: [(String, String)], of base: [(String, String)]) -> [(String, String)] {
        var overrides: [(String, String)] = []
        for index in bindings.indices where bindings[index].1 != base[index].1 {
            overrides.append(bindings[index])
        }
        return overrides
    }
}
