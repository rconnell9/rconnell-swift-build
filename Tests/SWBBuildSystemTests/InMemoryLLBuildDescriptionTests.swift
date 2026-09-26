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

import SWBBuildSystem
import SWBCore
import SWBTestSupport
import SWBTaskExecution
@_spi(Testing) import SWBUtil
import SwiftBuildTestSupport

/// End-to-end coverage for `useInMemoryLLBuildDescription`: instead of writing a
/// manifest for llbuild to re-parse, the build graph is handed to llbuild
/// directly in memory via the `BuildDescriptionBuilder` bindings. These tests
/// verify a real build driven through that path produces the same, correct
/// result as the default manifest-parsing path.
@Suite
fileprivate struct InMemoryLLBuildDescriptionTests: CoreBasedTests {
    /// Build a small C framework with the in-memory description path enabled and
    /// confirm it compiles, links, and produces the product binary with no
    /// diagnostics — exercising the shell / mkdir / symlink / phony / in-process
    /// command types through the FFI driver.
    @Test(.requireSDKs(.macOS))
    func buildsFrameworkViaInMemoryDescription() async throws {
        try await withEnvironment(["UseInMemoryLLBuildDescription": "YES"]) {
            try await withTemporaryDirectory { tmpDirPath in
                let testProject = TestProject(
                    "aProject",
                    sourceRoot: tmpDirPath,
                    groupTree: TestGroup(
                        "Sources",
                        children: [
                            TestFile("Foo.c"),
                            TestFile("Foo.h"),
                        ]),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                            "GENERATE_INFOPLIST_FILE": "YES",
                            "DEFINES_MODULE": "YES",
                        ])],
                    targets: [
                        TestStandardTarget(
                            "Foo",
                            type: .framework,
                            buildPhases: [
                                TestSourcesBuildPhase(["Foo.c"]),
                                TestHeadersBuildPhase([
                                    TestBuildFile("Foo.h", headerVisibility: .public),
                                ]),
                            ]),
                    ])

                let core = try await getCore()
                let tester = try await BuildOperationTester(core, testProject, simulated: false)
                let SRCROOT = tester.workspace.projects[0].sourceRoot.str

                try tester.fs.createDirectory(Path(SRCROOT), recursive: true)
                try tester.fs.write(Path(SRCROOT).join("Foo.h"), contents: "int foo(void);\n")
                try tester.fs.write(Path(SRCROOT).join("Foo.c"), contents: "int foo(void) { return 42; }\n")

                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    // The build must succeed with no warnings/errors. Any failure to
                    // reconstruct the description would surface as a hard build error
                    // (or the "falling back to manifest parsing" warning below).
                    results.checkNoDiagnostics()

                    // The compile and link tasks must have run.
                    results.checkTask(.matchRuleType("CompileC")) { _ in }
                    results.checkTask(.matchRuleType("Ld")) { _ in }

                    // And produced the framework binary.
                    results.checkFileExists(Path("\(SRCROOT)/build/Debug/Foo.framework/Versions/A/Foo"))

                    // No manifest was written. This is the point of the feature, and
                    // the one claim the build result itself cannot imply: a build that
                    // succeeds having *also* written the file would look identical.
                    results.checkFileDoesNotExist(results.buildDescription.manifestPath)
                }

                // A second build must be null: replaying the same graph into llbuild
                // twice has to produce the same command signatures, so llbuild sees no
                // work to do. Both builds here are in-memory — crossing between the
                // two paths is `nullBuildAcrossDescriptionPaths` below.
                try await tester.checkNullBuild(runDestination: .macOS, persistent: true)
            }
        }
    }

    /// Two script phases whose environments share a key list but differ in one
    /// value: the first declares the shared base, the second reuses it with a
    /// single override. This is the case `EnvironmentBaseTable` exists for, and the
    /// thing it must not get wrong — if llbuild substituted the override anywhere
    /// but in place of the base's own binding, or dropped it, the scripts would see
    /// the wrong value.
    @Test(.requireSDKs(.macOS))
    func factoredEnvironmentReachesScriptTasks() async throws {
        try await withEnvironment(["UseInMemoryLLBuildDescription": "YES"]) {
            try await withTemporaryDirectory { tmpDirPath in
                let firstOutput = tmpDirPath.join("marker-one.txt")
                let secondOutput = tmpDirPath.join("marker-two.txt")

                let testProject = TestProject(
                    "aProject",
                    sourceRoot: tmpDirPath,
                    groupTree: TestGroup("Sources", children: []),
                    buildConfigurations: [TestBuildConfiguration(
                        "Debug",
                        buildSettings: [
                            "PRODUCT_NAME": "$(TARGET_NAME)",
                        ])],
                    targets: [
                        TestAggregateTarget(
                            "One",
                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["MY_MARKER": "one"])],
                            buildPhases: [
                                TestShellScriptBuildPhase(
                                    name: "Emit", originalObjectID: "EmitOne",
                                    contents: "echo \"$MY_MARKER\" > \"$SCRIPT_OUTPUT_FILE_0\"",
                                    inputs: [], outputs: [firstOutput.str]),
                            ]),
                        TestAggregateTarget(
                            "Two",
                            buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: ["MY_MARKER": "two"])],
                            buildPhases: [
                                TestShellScriptBuildPhase(
                                    name: "Emit", originalObjectID: "EmitTwo",
                                    contents: "echo \"$MY_MARKER\" > \"$SCRIPT_OUTPUT_FILE_0\"",
                                    inputs: [], outputs: [secondOutput.str]),
                            ]),
                    ])

                let core = try await getCore()
                let tester = try await BuildOperationTester(core, testProject, simulated: false)

                // Both targets have to be in the same build, since the point is two
                // commands sharing an environment base within one description.
                let parameters = BuildParameters(configuration: "Debug")
                let buildRequest = BuildRequest(
                    parameters: parameters,
                    buildTargets: tester.workspace.projects[0].targets.map { BuildRequest.BuildTargetInfo(parameters: parameters, target: $0) },
                    dependencyScope: .workspace, continueBuildingAfterErrors: false,
                    useParallelTargets: true, useImplicitDependencies: false, useDryRun: false)

                try await tester.checkBuild(runDestination: .macOS, buildRequest: buildRequest, persistent: true) { results in
                    results.checkNoDiagnostics()
                    results.checkTasks(.matchRuleType("PhaseScriptExecution")) { tasks in
                        #expect(tasks.count == 2)
                    }
                }

                #expect(try tester.fs.read(firstOutput).asString == "one\n")
                #expect(try tester.fs.read(secondOutput).asString == "two\n")
            }
        }
    }

    /// The two paths must be interchangeable *within* an incremental build: they
    /// describe the same commands with the same signatures, so flipping the flag
    /// between builds must not invalidate llbuild's database. The in-memory path
    /// goes first, because that's the direction where no manifest is written at
    /// all and the manifest path has to pick up from a description that never
    /// produced one.
    @Test(.requireSDKs(.macOS))
    func nullBuildAcrossDescriptionPaths() async throws {
        try await withTemporaryDirectory { tmpDirPath in
            let testProject = TestProject(
                "aProject",
                sourceRoot: tmpDirPath,
                groupTree: TestGroup(
                    "Sources",
                    children: [
                        TestFile("Foo.c"),
                    ]),
                buildConfigurations: [TestBuildConfiguration(
                    "Debug",
                    buildSettings: [
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ])],
                targets: [
                    TestStandardTarget(
                        "Foo",
                        type: .framework,
                        buildPhases: [
                            TestSourcesBuildPhase(["Foo.c"]),
                        ]),
                ])

            let core = try await getCore()
            let tester = try await BuildOperationTester(core, testProject, simulated: false)
            let SRCROOT = tester.workspace.projects[0].sourceRoot

            try tester.fs.createDirectory(SRCROOT, recursive: true)
            try tester.fs.write(SRCROOT.join("Foo.c"), contents: "int foo(void) { return 42; }\n")

            try await withEnvironment(["UseInMemoryLLBuildDescription": "YES"]) {
                try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                    results.checkNoDiagnostics()
                }
            }

            // Manifest path, against a database populated in memory.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true)

            // And back, against a database the manifest path last touched.
            try await withEnvironment(["UseInMemoryLLBuildDescription": "YES"]) {
                try await tester.checkNullBuild(runDestination: .macOS, persistent: true)
            }
        }
    }
}
