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
import SWBCore

/// Where a command being emitted by `emitLLBuildCommand` is written to.
///
/// There is one conformance today: `LLBuildBuilderCommandSink`, over llbuild's
/// in-memory `BuildDescriptionBuilder` (the C API). The `manifest.json` writer --
/// `SWBTaskExecution.BuildDescriptionBuilder`, a different type of the same name --
/// emits the same commands, but writes its JSON directly rather than through this
/// protocol, so the two emitters have to be kept in step by hand.
///
/// A sink is stateful: `beginCommand` opens a command, the `set*` calls apply to
/// the open one, and `finishCommand` closes it. That keeps the emitter free of a
/// handle type it would otherwise have to be generic over, and leaves room for a
/// JSON sink to be added without changing the emitter.
protocol LLBuildCommandSink: AnyObject {
    /// Open a command. Returns `false` if it could not be created (e.g. an
    /// unknown tool), which aborts emission.
    func beginCommand(name: String, tool: String) -> Bool

    func setInputs(_ nodes: [String])
    func setOutputs(_ nodes: [String])
    func setDescription(_ description: String)

    func setAttribute(_ name: String, _ value: String)

    /// Record a boolean-valued attribute.
    ///
    /// Spelled separately from the string form because the C API takes a string
    /// while the manifest writes a bare JSON boolean. llbuild reads both as the
    /// same scalar, so keeping them distinct is what would let a JSON sink write
    /// the manifest's bytes unchanged.
    func setAttribute(_ name: String, bool value: Bool)

    func setAttribute(_ name: String, values: [String])

    /// Record a list-valued attribute whose elements are not necessarily valid
    /// UTF-8. Command lines take this path so that a sink can write their exact
    /// bytes rather than round-tripping them through `String`.
    func setAttribute(_ name: String, byteValues: [ByteString])

    func setAttribute(_ name: String, pairs: [(String, String)])

    /// Declare a shared environment table, before any command references it.
    func declareEnvironmentBase(_ base: String, bindings: [(String, String)])

    /// Point the open command at a previously declared environment base.
    func setEnvironmentBase(_ base: String)

    /// Close the open command.
    func finishCommand()
}

/// Emit `task` as a single llbuild command into `sink`.
///
/// This is the one place that decides what a Swift Build task looks like to
/// llbuild on the in-memory path: which tool it maps to, and which attributes it
/// carries. The `manifest.json` writer (`BuildDescriptionBuilder`'s
/// `addSubprocessCommand` and friends) makes the same decisions in JSON, and the
/// two must agree, because llbuild's database is keyed on command signatures.
///
/// What keeps them agreeing is that neither one computes a signature. Both emit
/// `signature-ignored-args` and `additional-signature-data` and leave llbuild to
/// derive the signature from the command line and environment it was configured
/// with; llbuild's `ShellCommand::configureAttribute` is shared between its YAML
/// reader and its builder API, so an attribute means the same thing however it
/// arrived. Routing the manifest writer through this function would make that
/// agreement structural instead of a matter of keeping two call sites in step --
/// it does not yet, so changes here need a matching change there.
///
/// The tool and attributes come from the task itself; the final input/output node
/// names -- real files plus the virtual gates that carry ordering -- and the
/// `repair-via-ownership-analysis` flag come from `nodeList`, which the frozen
/// task store recorded after input/output amendment.
///
/// Attributes are emitted in the order the `manifest.json` writer writes them, per
/// tool. llbuild is order-insensitive here, so nothing depends on it; it only
/// makes the two emitters readable side by side.
///
/// `environmentBases` factors the shared bulk out of command environments; see
/// ``EnvironmentBaseTable``. The caller must have declared its bases on `sink`
/// already, and must have built it over `environmentToEmit` for every task it is
/// about to emit -- an empty table simply sends every environment whole.
///
/// Returns `false` if the command could not be created.
func emitLLBuildCommand(
    task: Task,
    nodeList: LLBuildNodeList,
    bypassActualTasks: Bool,
    environmentBases: EnvironmentBaseTable,
    into sink: any LLBuildCommandSink
) -> Bool {
    let name = task.identifier.rawValue

    /// Open a command, apply the pieces every tool shares, run `configure`, then
    /// close it.
    ///
    /// `repair-via-ownership-analysis` is applied after `configure` for the tools
    /// that write it last, and by `configure` itself for `shell`, which has
    /// attributes that follow it.
    func emit(tool: String, description: String?, repairLast: Bool = true, configure: () -> Void) -> Bool {
        guard sink.beginCommand(name: name, tool: tool) else {
            return false
        }
        if let description {
            sink.setDescription(description)
        }
        // Always offered, even when empty: the manifest has always written both
        // keys unconditionally, while the builder skips empty lists. That choice
        // belongs to the sink.
        sink.setInputs(nodeList.inputs)
        sink.setOutputs(nodeList.outputs)
        configure()
        if repairLast && nodeList.repairViaOwnershipAnalysis {
            sink.setAttribute("repair-via-ownership-analysis", bool: true)
        }
        sink.finishCommand()
        return true
    }

    // Gate tasks map to a phony command, which carries nothing but its edges.
    if task.isGate {
        return emit(tool: "phony", description: nil) {}
    }

    let ruleInfo = task.ruleInfo
    let allowMissingInputs = (ruleInfo.first == "PhaseScriptExecution" ? !SWBFeatureFlag.disableShellScriptAllowsMissingInputs.value : false)
        || ruleInfo.first == "ValidateDevelopmentAssets"

    /// A `shell` command: the general case, and the only one with an environment,
    /// a command line, or signature adjustments.
    func emitShell(commandLine: [ByteString], environment: EnvironmentBindings?, workingDirectory: Path?, alwaysOutOfDate: Bool, deps: DependencyDataStyle?, isUnsafeToInterrupt: Bool, llbuildControlDisabled: Bool) -> Bool {
        var commandLine = commandLine
        if bypassActualTasks {
            commandLine = [ByteString(encodingAsUTF8: "/usr/bin/true")] + commandLine
        }

        return emit(tool: "shell", description: ruleInfo.joined(separator: " "), repairLast: false) {
            sink.setAttribute("args", byteValues: commandLine)
            if let environment {
                switch environmentBases.encoding(for: environment.bindings) {
                case .inline:
                    sink.setAttribute("env", pairs: environment.bindings)
                case .useBase(let base, let overrides):
                    sink.setEnvironmentBase(base)
                    // Sending nothing means the base is the whole environment.
                    if !overrides.isEmpty {
                        sink.setAttribute("env", pairs: overrides)
                    }
                }
            }
            if allowMissingInputs {
                sink.setAttribute("allow-missing-inputs", bool: true)
            }
            if alwaysOutOfDate {
                sink.setAttribute("always-out-of-date", bool: true)
            }
            if isUnsafeToInterrupt {
                sink.setAttribute("can-safely-interrupt", bool: false)
            }
            if let workingDirectory {
                sink.setAttribute("working-directory", workingDirectory.str)
            }
            if llbuildControlDisabled {
                // Disable the control file descriptor.
                sink.setAttribute("control-enabled", bool: false)
            }
            if let deps {
                sink.setAttribute("deps", values: deps.paths.map { $0.str })
                sink.setAttribute("deps-style", deps.name)
            }
            if nodeList.repairViaOwnershipAnalysis {
                sink.setAttribute("repair-via-ownership-analysis", bool: true)
            }

            // llbuild computes the signature itself, from the command line and
            // environment it was configured with -- which is the whole reason the
            // in-memory path can hand over a graph without hashing it first. All we
            // add is what llbuild cannot know: which arguments have no bearing on
            // the outputs, and state of ours the command line does not show.
            let signatureIgnoredArgs = task.type.signatureIgnoredArgumentIndices(for: task)
            if !signatureIgnoredArgs.isEmpty {
                // `bypassActualTasks` prepended an argument, shifting the indices.
                let offset = bypassActualTasks ? 1 : 0
                sink.setAttribute("signature-ignored-args", values: signatureIgnoredArgs.map { String($0 + offset) })
            }
            if !task.additionalSignatureData.isEmpty {
                sink.setAttribute("additional-signature-data", task.additionalSignatureData)
            }
        }
    }

    // Custom tasks (in-process task actions) map to their tool identifier. Under
    // `bypassActualTasks` they degrade to a `/usr/bin/true` shell command.
    if let action = task.action {
        if bypassActualTasks {
            // Both paths have always passed an explicit `/usr/bin/true` here, which
            // `emitShell` then prepends to again -- so the bypassed command line is
            // `/usr/bin/true /usr/bin/true`. Preserved deliberately: changing it
            // would change every bypassed command's signature.
            return emitShell(commandLine: [ByteString(encodingAsUTF8: "/usr/bin/true")], environment: nil, workingDirectory: nil, alwaysOutOfDate: task.alwaysExecuteTask, deps: nil, isUnsafeToInterrupt: false, llbuildControlDisabled: false)
        }
        return emit(tool: Swift.type(of: action).toolIdentifier, description: ruleInfo.joined(separator: " ")) {
            // Unlike `shell`, a custom tool takes a single dependency-info path
            // rather than a list plus a style.
            if let deps = task.dependencyData, case .dependencyInfo(let path) = deps {
                sink.setAttribute("deps", path.str)
            }
            if allowMissingInputs {
                sink.setAttribute("allow-missing-inputs", bool: true)
            }
            if task.alwaysExecuteTask {
                sink.setAttribute("always-out-of-date", bool: true)
            }
        }
    }

    // Otherwise, delegate based on the task type.
    switch ruleInfo[0] {
    case "MkDir":
        return emit(tool: "mkdir", description: ruleInfo.joined(separator: " ")) {}

    case "SymLink":
        return emit(tool: "symlink", description: ruleInfo.joined(separator: " ")) {
            sink.setAttribute("contents", ruleInfo[2])
        }

    default:
        return emitShell(commandLine: task.commandLine.map(\.asByteString), environment: task.environmentToEmit, workingDirectory: task.workingDirectory, alwaysOutOfDate: task.alwaysExecuteTask, deps: task.dependencyData, isUnsafeToInterrupt: task.type.isUnsafeToInterrupt, llbuildControlDisabled: task.llbuildControlDisabled)
    }
}

extension Task {
    /// The environment this task's llbuild command will carry, or `nil` where it
    /// takes a path through `emitLLBuildCommand` that has none.
    ///
    /// ``EnvironmentBaseTable`` is built from these before any command is emitted,
    /// so the two have to agree: an environment collected here that never reaches a
    /// command leaves a base nothing references, and one that reaches a command
    /// without having been collected is merely sent inline. `emitLLBuildCommand`
    /// reads this rather than `environment` directly, so the two cannot drift.
    ///
    /// This mirrors `ConstructedTask.environmentToDescribe`, which answers the same
    /// question on the manifest side, from the planned task rather than the
    /// executable one.
    var environmentToEmit: EnvironmentBindings? {
        guard !isGate, action == nil else { return nil }
        switch ruleInfo[0] {
        case "MkDir", "SymLink":
            return nil
        default:
            return environment
        }
    }
}
