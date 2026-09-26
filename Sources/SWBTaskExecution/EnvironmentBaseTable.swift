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
/// values, thousands of times over -- which on a large project is the majority of
/// the build manifest's bytes. (Measured on WebKit: 4,102 non-empty environments,
/// 4,014 of them distinct, but only 123 distinct key sets.)
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
    private struct Base: Sendable {
        /// The bindings the base was declared with, in order. Every member of the
        /// group has this same key list, index for index, so computing a member's
        /// overrides is a walk of two arrays rather than a map lookup per
        /// variable.
        let bindings: [(String, String)]

        let name: String

        /// Set when this key list cannot be represented as a base, in which case
        /// its members send their environments whole. See `register(_:)`.
        let unfactorable: Bool
    }

    /// Environments smaller than this are sent inline. Factoring costs a base
    /// declaration plus an `env-base` attribute, which is only worth paying where
    /// there is real bulk to share -- and the environments this exists for hold
    /// hundreds of variables.
    private static let minimumBindingsToFactor = 8

    private var bases: [Base] = []

    /// Candidate bases by hash of the key list. A bucket holds more than one entry
    /// only on hash collision, which the key comparison then resolves.
    private var basesByKeysHash: [Int: [Int]] = [:]

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
    }

    /// The bases to declare, in the order they were first needed.
    package var declaredBases: [(name: String, bindings: [(String, String)])] {
        bases.lazy.filter { !$0.unfactorable }.map { ($0.name, $0.bindings) }
    }

    /// How `bindings` should be sent, given the bases this table holds.
    ///
    /// An environment that was never registered -- or one whose key list could not
    /// be factored -- is sent whole.
    package func factoring(for bindings: [(String, String)]) -> EnvironmentFactoring {
        guard let base = base(forKeysOf: bindings), !base.unfactorable else { return .inline }
        return .useBase(base: base.name, overrides: overrides(in: bindings, of: base.bindings))
    }

    private mutating func register(_ bindings: [(String, String)]) {
        guard bindings.count >= Self.minimumBindingsToFactor else { return }
        guard base(forKeysOf: bindings) == nil else { return }

        // The first environment registered with these keys defines the base for
        // the rest.
        //
        // A duplicated key would not survive the round trip -- the base holds one
        // binding per key, and an override substitutes in place rather than
        // repeating -- so such a key list is recorded as unfactorable rather than
        // silently collapsed. Bindings come from a dictionary in practice, so this
        // is a guard rather than a case worth optimizing.
        let unfactorable = Set(bindings.lazy.map { $0.0 }).count != bindings.count
        let name = "env-base-\(bases.count)"
        bases.append(Base(bindings: bindings, name: name, unfactorable: unfactorable))
        basesByKeysHash[Self.keysHash(of: bindings), default: []].append(bases.count - 1)
    }

    private func base(forKeysOf bindings: [(String, String)]) -> Base? {
        guard bindings.count >= Self.minimumBindingsToFactor else { return nil }
        for index in basesByKeysHash[Self.keysHash(of: bindings)] ?? [] where hasSameKeys(bases[index].bindings, bindings) {
            return bases[index]
        }
        return nil
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
