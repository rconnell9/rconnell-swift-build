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

import Testing

import SWBTaskExecution

@Suite
fileprivate struct EnvironmentBaseTableTests {

    private func bindings(_ overrides: [String: String] = [:], count: Int = 12) -> [(String, String)] {
        (0..<count).map { index in
            let key = "VAR_\(index)"
            return (key, overrides[key] ?? "shared-\(index)")
        }
    }

    /// llbuild's effective environment for a command encoded against a base
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

    /// An environment identical to its base sends nothing at all
    @Test
    func identicalEnvironmentSendsNoOverrides() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings()])

        guard case .useBase(let base, let overrides) = table.encoding(for: bindings()) else {
            Issue.record("expected an identical environment to reuse the base")
            return
        }
        #expect(base == "env-base-0")
        #expect(overrides.isEmpty)
    }

    /// The point of the whole thing: a command differing in a few values sends those
    /// bindings instead of all twelve
    @Test(arguments: [[0], [11], [3, 7], Array(0..<12)])
    func differingValuesAreSentAsOverrides(differing: [Int]) {
        let baseEnvironment = bindings()
        let environment = bindings(Dictionary(uniqueKeysWithValues: differing.map { ("VAR_\($0)", "mine-\($0)") }))
        let table = EnvironmentBaseTable(environments: [baseEnvironment, environment])

        guard case .useBase(_, let overrides) = table.encoding(for: environment) else {
            Issue.record("expected the second environment to reuse the base")
            return
        }
        #expect(overrides.map { $0.0 } == differing.map { "VAR_\($0)" })

        let effective = effectiveEnvironment(base: baseEnvironment, overrides: overrides)
        #expect(effective.map { "\($0.0)=\($0.1)" } == environment.map { "\($0.0)=\($0.1)" })
    }

    /// Two environments with the same keys in a different order cannot share a
    /// base
    @Test
    func reorderedKeysGetSeparateBases() {
        let environment = bindings()
        let reordered = Array(environment.reversed())
        let table = EnvironmentBaseTable(environments: [environment, environment, reordered, reordered])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: environment) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.encoding(for: reordered) == .useBase(base: "env-base-1", overrides: []))
    }

    /// A different key list gets its own base rather than inheriting one whose
    /// keys it would have to append to.
    @Test
    func differentKeysGetSeparateBases() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings(), bindings(count: 13), bindings(count: 13)])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: bindings(count: 13)) == .useBase(base: "env-base-1", overrides: []))
    }

    @Test
    func keyListUsedOnceIsSentInline() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings(count: 400)])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: bindings()) == .inline)
        #expect(table.encoding(for: bindings(count: 400)) == .inline)
    }

    @Test
    func smallSharedEnvironmentGetsABase() {
        let environment = bindings(count: 1)
        let table = EnvironmentBaseTable(environments: [environment, environment])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0"])
        #expect(table.encoding(for: environment) == .useBase(base: "env-base-0", overrides: []))
    }

    @Test
    func baseNamesSkipKeyListsUsedOnce() {
        let shared = bindings()
        let once = bindings(count: 5)
        let alsoShared = bindings(count: 13)
        let table = EnvironmentBaseTable(environments: [shared, shared, once, alsoShared, alsoShared])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: shared) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.encoding(for: once) == .inline)
        #expect(table.encoding(for: alsoShared) == .useBase(base: "env-base-1", overrides: []))
    }

    @Test
    func duplicateKeysAreSentInline() {
        let environment = bindings() + [("VAR_0", "again")]
        let table = EnvironmentBaseTable(environments: [environment, environment])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: environment) == .inline)
    }

    @Test
    func emptyEnvironmentIsSentInline() {
        let table = EnvironmentBaseTable(environments: [[]])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: []) == .inline)
    }

    @Test
    func unregisteredEnvironmentIsSentInline() {
        let table = EnvironmentBaseTable(environments: [bindings(), bindings()])

        #expect(table.declaredBases.count == 1)
        #expect(table.encoding(for: bindings(count: 20)) == .inline)
    }

    @Test
    func encodingDoesNotDependOnQueryOrder() {
        let environments = [bindings(), bindings(["VAR_1": "a"]), bindings(["VAR_2": "b"])]
        let table = EnvironmentBaseTable(environments: environments)

        let forward = environments.map { table.encoding(for: $0) }
        let backward = environments.reversed().map { table.encoding(for: $0) }
        #expect(forward == Array(backward.reversed()))
    }

    /// ``EnvironmentBaseTable/encodings``, which answers from what registration
    /// already worked out, has to produce exactly what asking the table per
    /// environment produces -- that equivalence is its whole licence to exist, since
    /// it is only there to avoid the per-command lookup.
    ///
    /// Arguments cover what the registration fast path (which compares an
    /// environment's keys against the previously registered ones in place, rather
    /// than hashing them) can get wrong: consecutive repeats that should hit it,
    /// interleaved key lists that should not, key lists differing only in length or
    /// order, and environments that cannot share a base at all.
    @Test(arguments: [
        // Consecutive repeats, including values differing from the base's.
        [0, 0, 0],
        [0, 1, 1, 2],
        // Interleaved, so no two neighbours share a key list.
        [0, 3, 0, 3, 0],
        // The same keys reordered, and a shorter key list -- neither can share a base
        // with the 12-variable environment.
        [0, 4, 0, 4],
        [0, 5, 5, 0],
        // A duplicate key, which makes a key list unshareable.
        [6, 6, 0, 0],
        // Key lists used once, which get no base.
        [0, 0, 5, 4],
        // Empty environments, which get no base, around ones that do.
        [7, 0, 7, 0, 7],
        [7, 7],
    ] as [[Int]])
    func factoringMatchesPerCommandEncoding(shape: [Int]) {
        // Each element of `shape` selects one of the environments below, so a shape
        // is a sequence of environments in registration order.
        let catalog: [[(String, String)]] = [
            bindings(),                                 // 0: the shared 12-variable environment
            bindings(["VAR_3": "mine"]),                // 1: same keys, one value differing
            bindings(["VAR_0": "a", "VAR_11": "b"]),    // 2: same keys, two values differing
            bindings(count: 13),                        // 3: a different key list
            Array(bindings().reversed()),               // 4: the same keys, reordered
            bindings(count: 5),                         // 5: a shorter key list
            bindings() + [("VAR_0", "again")],          // 6: a duplicate key, so unshareable
            [],                                         // 7: empty
        ]
        let environments = shape.map { catalog[$0] }

        let table = EnvironmentBaseTable(environments: environments)
        let encodings = table.encodings

        #expect(encodings == environments.map { table.encoding(for: $0) })

        // The encodings have to be usable, not merely self-consistent: every command's
        // effective environment must still be what it started with.
        for (environment, encoding) in zip(environments, encodings) {
            switch encoding {
            case .inline:
                break
            case .useBase(let name, let overrides):
                let base = try? #require(table.declaredBases.first { $0.name == name }).bindings
                #expect(effectiveEnvironment(base: base ?? [], overrides: overrides).map { "\($0.0)=\($0.1)" }
                        == environment.map { "\($0.0)=\($0.1)" })
            }
        }
    }
}
