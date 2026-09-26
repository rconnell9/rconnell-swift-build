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

import SWBCore
import SWBTestSupport
import SWBUtil
import SwiftBuildTestSupport

/// End-to-end coverage for the shared environment bases that `EnvironmentBaseTable`
/// factors out of the llbuild manifest.
///
/// The unit tests in `EnvironmentBaseTableTests` cover the factoring itself; what
/// these add is that llbuild accepts the resulting manifest and reconstitutes the
/// same environments from it. A mistake there would not show up as a parse error --
/// it would show up as a build that never goes null, because every command's
/// signature is computed over its effective environment.
@Suite
fileprivate struct EnvironmentBaseBuildOperationTests: CoreBasedTests {
    /// A script phase is the reliable way to get environments worth factoring: script
    /// commands carry the whole build-settings environment, hundreds of variables
    /// that two scripts in the same target share almost entirely.
    @Test(.requireSDKs(.macOS))
    func scriptEnvironmentsAreFactoredAndReconstituted() async throws {
        try await withTemporaryDirectory { tmpDir in
            let testProject = TestProject(
                "aProject",
                groupTree: TestGroup("Sources", children: [TestFile("main.c")]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "CODE_SIGNING_ALLOWED": "NO",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "GENERATE_INFOPLIST_FILE": "YES",
                    ]),
                ],
                targets: [
                    TestStandardTarget(
                        "Tool",
                        type: .commandLineTool,
                        buildPhases: [
                            TestSourcesBuildPhase(["main.c"]),
                            // Two scripts with the same environment but for one
                            // variable, which is the shape the factoring is for.
                            TestShellScriptBuildPhase(name: "First", originalObjectID: "first", contents: "echo first > \"$SCRIPT_OUTPUT_FILE_0\"", outputs: [tmpDir.join("first.txt").str]),
                            TestShellScriptBuildPhase(name: "Second", originalObjectID: "second", contents: "echo second > \"$SCRIPT_OUTPUT_FILE_0\"", outputs: [tmpDir.join("second.txt").str]),
                        ]),
                ])
            let tester = try await BuildOperationTester(getCore(), testProject, simulated: false)
            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("main.c")) { $0 <<< "int main() { return 0; }\n" }

            try await tester.checkBuild(runDestination: .macOS, persistent: true) { results in
                results.checkNoDiagnostics()

                let manifest = try results.readLLBuildManifestContents()
                // The scripts are factored onto a base rather than carrying their
                // environments whole.
                #expect(manifest.contains(#""env-bases":{"#), Comment(rawValue: manifest))
                #expect(manifest.contains(#""env-base":"env-base-0""#), Comment(rawValue: manifest))
            }

            // The build goes null, which is the assertion that matters: llbuild
            // recomposed each script's environment from its base into the same
            // effective environment, so the signatures it stored on the first build
            // still match.
            try await tester.checkNullBuild(runDestination: .macOS, persistent: true, excludedTasks: ["ClangStatCache", "LinkAssetCatalogSignature", "Gate"])
        }
    }
}
