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

import SWBCore
import SWBTaskExecution

@Suite
fileprivate struct EnvironmentBaseTableTests {

    private func bindings(_ overrides: [String: String] = [:], count: Int = 12) -> [(String, String)] {
        (0..<count).map { index in
            let key = "VAR_\(index)"
            return (key, overrides[key] ?? "shared-\(index)")
        }
    }

    private func command(_ name: String) -> TaskIdentifier {
        TaskIdentifier(rawValue: name)
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
        let table = EnvironmentBaseTable(environments: [(command("first"), environment), (command("second"), bindings(["VAR_3": "mine"]))])

        let declared = table.declaredBases
        #expect(declared.count == 1)
        #expect(declared.first?.name == "env-base-0")
        #expect(declared.first?.bindings.map { "\($0.0)=\($0.1)" } == environment.map { "\($0.0)=\($0.1)" })
    }

    /// An environment identical to its base sends nothing at all
    @Test
    func identicalEnvironmentSendsNoOverrides() {
        let table = EnvironmentBaseTable(environments: [(command("first"), bindings()), (command("second"), bindings())])

        guard case .useBase(let base, let overrides) = table.encoding(for: command("second")) else {
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
        let table = EnvironmentBaseTable(environments: [(command("first"), baseEnvironment), (command("second"), environment)])

        guard case .useBase(_, let overrides) = table.encoding(for: command("second")) else {
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
        let table = EnvironmentBaseTable(environments: [
            (command("ordered"), environment), (command("ordered-again"), environment),
            (command("reordered"), reordered), (command("reordered-again"), reordered),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: command("ordered-again")) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.encoding(for: command("reordered-again")) == .useBase(base: "env-base-1", overrides: []))
    }

    /// A different key list gets its own base rather than inheriting one whose
    /// keys it would have to append to.
    @Test
    func differentKeysGetSeparateBases() {
        let table = EnvironmentBaseTable(environments: [
            (command("twelve"), bindings()), (command("twelve-again"), bindings()),
            (command("thirteen"), bindings(count: 13)), (command("thirteen-again"), bindings(count: 13)),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: command("thirteen-again")) == .useBase(base: "env-base-1", overrides: []))
    }

    @Test
    func keyListUsedOnceIsSentInline() {
        let table = EnvironmentBaseTable(environments: [(command("twelve"), bindings()), (command("four-hundred"), bindings(count: 400))])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: command("twelve")) == .inline)
        #expect(table.encoding(for: command("four-hundred")) == .inline)
    }

    @Test
    func smallSharedEnvironmentGetsABase() {
        let environment = bindings(count: 1)
        let table = EnvironmentBaseTable(environments: [(command("first"), environment), (command("second"), environment)])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0"])
        #expect(table.encoding(for: command("second")) == .useBase(base: "env-base-0", overrides: []))
    }

    @Test
    func baseNamesSkipKeyListsUsedOnce() {
        let shared = bindings()
        let once = bindings(count: 5)
        let alsoShared = bindings(count: 13)
        let table = EnvironmentBaseTable(environments: [
            (command("shared"), shared), (command("shared-again"), shared),
            (command("once"), once),
            (command("also-shared"), alsoShared), (command("also-shared-again"), alsoShared),
        ])

        #expect(table.declaredBases.map { $0.name } == ["env-base-0", "env-base-1"])
        #expect(table.encoding(for: command("shared-again")) == .useBase(base: "env-base-0", overrides: []))
        #expect(table.encoding(for: command("once")) == .inline)
        #expect(table.encoding(for: command("also-shared-again")) == .useBase(base: "env-base-1", overrides: []))
    }

    @Test
    func duplicateKeysAreSentInline() {
        let environment = bindings() + [("VAR_0", "again")]
        let table = EnvironmentBaseTable(environments: [(command("first"), environment), (command("second"), environment)])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: command("second")) == .inline)
    }

    @Test
    func emptyEnvironmentIsSentInline() {
        let table = EnvironmentBaseTable(environments: [(command("empty"), [])])

        #expect(table.declaredBases.isEmpty)
        #expect(table.encoding(for: command("empty")) == .inline)
    }

    /// A command the table was not built over -- one whose environment reaches
    /// llbuild without having been registered -- is sent whole rather than
    /// mis-encoded.
    @Test
    func unregisteredCommandIsSentInline() {
        let table = EnvironmentBaseTable(environments: [(command("first"), bindings()), (command("second"), bindings())])

        #expect(table.declaredBases.count == 1)
        #expect(table.encoding(for: command("never-registered")) == .inline)
    }

    /// Whatever the table decides, every command's effective environment has to be
    /// the one it started with -- that is the one thing the factoring is not allowed
    /// to change.
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
    func factoringPreservesEveryEnvironment(shape: [Int]) {
        // Each element of `shape` selects one of the environments below, so a shape
        // is a sequence of commands' environments in registration order.
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
        let commands = shape.enumerated().map { (command("command-\($0.offset)"), catalog[$0.element]) }
        let table = EnvironmentBaseTable(environments: commands)

        for (command, environment) in commands {
            switch table.encoding(for: command) {
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
