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

import SWBTaskExecution

/// Coverage for `EnvironmentBaseTable`, which decides how each command's
/// environment is handed to llbuild.
///
/// The invariant these tests protect is that a factored environment reconstitutes
/// to *exactly* the original -- same values, same order -- because llbuild
/// substitutes an override in place of the base's binding. If it did not, every
/// command's signature would shift the first time a build took the factored path.
@Suite
fileprivate struct EnvironmentBaseTableTests {
    /// An environment of a representative shape: enough variables that overrides are
    /// visibly a small part of it.
    private func bindings(_ overrides: [String: String] = [:], count: Int = 12) -> [(String, String)] {
        (0..<count).map { index in
            let key = "VAR_\(index)"
            return (key, overrides[key] ?? "shared-\(index)")
        }
    }

    /// llbuild's effective environment for a factored command: the base, with
    /// overrides substituted in place and unknown keys appended. This mirrors
    /// `ShellCommand::getEffectiveEnv`, so the equivalence assertions below are
    /// about the same combination llbuild will perform.
    private func effectiveEnvironment(base: [(String, String)], overrides: [(String, String)]) -> [(String, String)] {
        var result = base
        for (key, value) in overrides {
            if let index = result.firstIndex(where: { $0.0 == key }) {
                result[index] = (key, value)
            } else {
                result.append((key, value))
            }
        }
        return result
    }

    /// The first environment registered with a given key list is the one the base
    /// is declared with.
    @Test
    func firstEnvironmentDeclaresTheBase() {
        let environment = bindings()
        let table = EnvironmentBaseTable(environments: [environment, bindings(["VAR_3": "mine"])])

        let declared = table.declaredBases
        #expect(declared.count == 1)
        #expect(declared.first?.name == "env-base-0")
        #expect(declared.first?.bindings.map { "\($0.0)=\($0.1)" } == environment.map { "\($0.0)=\($0.1)" })
    }

    /// An environment identical to its base sends nothing at all -- the case that
    /// does the bulk of the work on the SwiftPM-shaped builds, where every command
    /// carries the same single large `PATH`.
    @Test
    func identicalEnvironmentSendsNoOverrides() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings()])

        guard case .useBase(let base, let overrides) = table.factoring(for: bindings()) else {
            Issue.record("expected an identical environment to reuse the base")
            return
        }
        #expect(base == "env-base-0")
        #expect(overrides.isEmpty)
    }

    /// The point of the whole thing: a command differing in two values sends two
    /// bindings instead of twelve, and still reconstitutes to exactly its original
    /// environment.
    @Test
    func differingValuesAreSentAsOverrides() {
        let baseEnvironment = bindings()
        let environment = bindings(["VAR_3": "mine", "VAR_7": "also-mine"])
        let table = EnvironmentBaseTable(environments: [baseEnvironment, environment])

        guard case .useBase(_, let overrides) = table.factoring(for: environment) else {
            Issue.record("expected the second environment to reuse the base")
            return
        }
        #expect(overrides.map { $0.0 } == ["VAR_3", "VAR_7"])

        let effective = effectiveEnvironment(base: baseEnvironment, overrides: overrides)
        #expect(effective.map { "\($0.0)=\($0.1)" } == environment.map { "\($0.0)=\($0.1)" })
    }

    /// Overrides substitute in place, so the reconstituted environment keeps the
    /// original ordering even when the *first* binding is the one that differs.
    /// Ordering is what signature stability rests on.
    @Test
    func overridingPreservesOrdering() {
        let baseEnvironment = bindings()
        let environment = bindings(["VAR_0": "first-differs"])
        let table = EnvironmentBaseTable(environments: [baseEnvironment, environment])

        guard case .useBase(_, let overrides) = table.factoring(for: environment) else {
            Issue.record("expected the second environment to reuse the base")
            return
        }

        let effective = effectiveEnvironment(base: baseEnvironment, overrides: overrides)
        #expect(effective.map { "\($0.0)=\($0.1)" } == environment.map { "\($0.0)=\($0.1)" })
    }

    /// Two environments with the same keys in a different *order* cannot share a
    /// base without reordering one of them, so each gets its own.
    @Test
    func reorderedKeysGetSeparateBases() {
        let environment = bindings()
        let reordered = Array(environment.reversed())
        let table = EnvironmentBaseTable(environments: [environment, environment, reordered, reordered])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.factoring(for: environment) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.factoring(for: reordered) == .useBase(base: "env-base-1", overrides: []))
    }

    /// A different key list gets its own base rather than inheriting one whose
    /// keys it would have to append to.
    @Test
    func differentKeysGetSeparateBases() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings(), bindings(count: 13), bindings(count: 13)])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.factoring(for: bindings(count: 13)) == .useBase(base: "env-base-1", overrides: []))
    }

    /// A key list only one command uses is sent inline: a base has to be declared
    /// in full, so factoring such an environment costs the whole of it again plus
    /// the reference.
    @Test
    func keyListUsedOnceIsSentInline() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings(count: 400)])

        #expect(table.declaredBases.isEmpty)
        #expect(table.factoring(for: bindings()) == .inline)
        #expect(table.factoring(for: bindings(count: 400)) == .inline)
    }

    /// Size is not the criterion -- two commands sharing even a single variable get
    /// a base. This is the SwiftPM shape, where the one variable is a `PATH` far
    /// larger than any name-count rule would suggest.
    @Test
    func smallSharedEnvironmentGetsABase() {
        let environment = bindings(count: 1)
        let table = EnvironmentBaseTable(environments: [environment, environment])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0"])
        #expect(table.factoring(for: environment) == .useBase(base: "env-base-0", overrides: []))
    }

    /// Names run consecutively over the bases actually declared, leaving no gap
    /// where a key list in between turned out to be used just once. A gap would be
    /// harmless to llbuild but would make a manifest diff needlessly hard to read.
    @Test
    func baseNamesSkipKeyListsUsedOnce() {
        let shared = bindings()
        let once = bindings(count: 5)
        let alsoShared = bindings(count: 13)
        let table = EnvironmentBaseTable(environments: [shared, shared, once, alsoShared, alsoShared])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.factoring(for: shared) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.factoring(for: once) == .inline)
        #expect(table.factoring(for: alsoShared) == .useBase(base: "env-base-1", overrides: []))
    }

    /// A duplicated key cannot survive the round trip -- a base holds one binding
    /// per key -- so such an environment is sent whole rather than silently
    /// collapsed. Every command sharing that key list must make the same choice,
    /// which is why the table records the key list as unfactorable rather than just
    /// declining to declare a base for it.
    @Test
    func duplicateKeysAreSentInline() {
        let environment = bindings() + [("VAR_0", "again")]
        let table = EnvironmentBaseTable(environments: [environment, environment])

        #expect(table.declaredBases.isEmpty)
        #expect(table.factoring(for: environment) == .inline)
    }

    /// An empty environment is nothing to factor.
    @Test
    func emptyEnvironmentIsSentInline() {
        let table = EnvironmentBaseTable(environments: [[]])

        #expect(table.declaredBases.isEmpty)
        #expect(table.factoring(for: []) == .inline)
    }

    /// An environment the table was never built over is sent whole. Nothing plans a
    /// command outside the pre-pass today, but the table must not invent a base for
    /// one that appears anyway.
    @Test
    func unregisteredEnvironmentIsSentInline() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings()])

        #expect(table.declaredBases.count == 1)
        #expect(table.factoring(for: bindings(count: 20)) == .inline)
    }

    /// The table's assignments depend only on the order it was built in, not on the
    /// order it is queried in -- the property that keeps a manifest byte-identical
    /// across two constructions even though its commands are described in parallel.
    @Test
    func factoringDoesNotDependOnQueryOrder() {
        let environments = [bindings(), bindings(["VAR_1": "a"]), bindings(["VAR_2": "b"])]
        let table = EnvironmentBaseTable(environments: environments)

        let forward = environments.map { table.factoring(for: $0) }
        let backward = environments.reversed().map { table.factoring(for: $0) }
        #expect(forward == Array(backward.reversed()))
    }
}
