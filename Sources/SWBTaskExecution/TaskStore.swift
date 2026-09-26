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

package import SWBCore
package import SWBUtil
import Synchronization

/// The per-task llbuild scheduling info Swift Build must remember to feed llbuild
/// directly when bypassing the manifest.json.  This extends what `Task` currently retains
/// for execution.
package struct LLBuildNodeList: Serializable, Sendable {
    package let inputs: [String]
    package let outputs: [String]
    package let repairViaOwnershipAnalysis: Bool

    package init(inputs: [String], outputs: [String], repairViaOwnershipAnalysis: Bool) {
        self.inputs = inputs
        self.outputs = outputs
        self.repairViaOwnershipAnalysis = repairViaOwnershipAnalysis
    }

    package func serialize<T: Serializer>(to serializer: T) {
        serializer.beginAggregate(3)
        serializer.serialize(inputs)
        serializer.serialize(outputs)
        serializer.serialize(repairViaOwnershipAnalysis)
        serializer.endAggregate()
    }

    package init(from deserializer: any Deserializer) throws {
        try deserializer.beginAggregate(3)
        self.inputs = try deserializer.deserialize()
        self.outputs = try deserializer.deserialize()
        self.repairViaOwnershipAnalysis = try deserializer.deserialize()
    }
}

package final class TaskStore {
    package enum Error: Swift.Error {
        case duplicateTaskIdentifier
    }

    private var tasks: [TaskIdentifier: (Task, Task.Storage.InternedStorage.Handles)]

    private var llbuildNodeLists: [TaskIdentifier: LLBuildNodeList]
    private let stringArena = StringArena()
    private let byteStringArena = ByteStringArena()

    init() {
        tasks = [:]
        llbuildNodeLists = [:]
    }

    package func insertTask(_ task: Task, llbuildInputs: [String], llbuildOutputs: [String], repairViaOwnershipAnalysis: Bool) throws -> TaskIdentifier {
        let id = task.identifier
        guard !tasks.keys.contains(id) else {
            throw Error.duplicateTaskIdentifier
        }
        tasks[id] = (task, task.internedStorage(byteStringArena: byteStringArena, stringArena: stringArena))
        llbuildNodeLists[id] = LLBuildNodeList(inputs: llbuildInputs, outputs: llbuildOutputs, repairViaOwnershipAnalysis: repairViaOwnershipAnalysis)
        return id
    }

    func freeze() -> FrozenTaskStore {
        let frozenStringArena = stringArena.freeze()
        let frozenByteStringArena = byteStringArena.freeze()
        let internedTasks = self.tasks.mapValues { taskAndStorage in
            Task(task: taskAndStorage.0, internedStorageHandles: taskAndStorage.1, frozenByteStringArena: frozenByteStringArena, frozenStringArena: frozenStringArena)
        }
        return FrozenTaskStore(tasks: internedTasks, llbuildNodeLists: llbuildNodeLists, stringArena: frozenStringArena, byteStringArena: frozenByteStringArena)
    }
}

// TaskStore is not Sendable
@available(*, unavailable) extension TaskStore: Sendable {}

package final class FrozenTaskStore: Sendable {
    fileprivate init(tasks: [TaskIdentifier : Task], llbuildNodeLists: [TaskIdentifier: LLBuildNodeList], stringArena: FrozenStringArena, byteStringArena: FrozenByteStringArena) {
        self.tasks = tasks
        self.llbuildNodeLists = llbuildNodeLists
        self.stringArena = stringArena
        self.byteStringArena = byteStringArena
    }

    private let tasks: [TaskIdentifier: Task]
    private let llbuildNodeLists: [TaskIdentifier: LLBuildNodeList]
    private let stringArena: FrozenStringArena
    private let byteStringArena: FrozenByteStringArena

    package var taskCount: Int {
        tasks.count
    }

    package func forEachTask(_ perform: (Task) -> Void) {
        for task in tasks.values {
            perform(task)
        }
    }

    /// Walk the tasks in identifier order, each with the llbuild node list recorded
    /// for it (`nil` only for a malformed store).
    ///
    /// The order matters: it is the same order `BuildDescription.construct` sorts
    /// into before describing commands, so the environment bases the in-memory path
    /// derives are the ones the manifest would have declared.
    package func forEachTaskInLLBuildOrder(_ perform: (Task, LLBuildNodeList?) -> Void) {
        for identifier in tasks.keys.sorted() {
            guard let task = tasks[identifier] else { continue }
            perform(task, llbuildNodeLists[identifier])
        }
    }

    package func task(for identifier: TaskIdentifier) -> Task? {
        tasks[identifier]
    }

    package func llbuildNodeList(for identifier: TaskIdentifier) -> LLBuildNodeList? {
        llbuildNodeLists[identifier]
    }

    package func taskAction(for identifier: TaskIdentifier) -> TaskAction? {
        tasks[identifier]?.action
    }

    /// It is beneficial for the performance of the index queries to have a mapping of tasks in each target.
    /// But since this is not broadly useful we only populate this lazily, on demand. This info is not serialized to the build description.
    private let tasksByTargetCache: SWBMutex<[ConfiguredTarget?: [Task]]> = .init([:])

    /// The tasks associated with a particular target.
    package func tasksForTarget(_ target: ConfiguredTarget?) -> [Task] {
        return tasksByTargetCache.withLock { tasksByTarget in
            tasksByTarget.getOrInsert(target) { tasks.values.filter { $0.forTarget == target } }
        }
    }
}

extension FrozenTaskStore: Serializable {
    package func serialize<T>(to serializer: T) where T : Serializer {
        serializer.beginAggregate(2)
        serializer.serialize(Array(tasks.values))
        serializer.serialize(llbuildNodeLists)
        serializer.endAggregate()
    }

    package convenience init(from deserializer: any SWBUtil.Deserializer) throws {
        try deserializer.beginAggregate(2)
        let taskArray: [Task] = try deserializer.deserialize()
        let llbuildNodeLists: [TaskIdentifier: LLBuildNodeList] = try deserializer.deserialize()
        let byteStringArena = ByteStringArena()
        let stringArena = StringArena()
        let tasks = Dictionary(uniqueKeysWithValues: taskArray.map { ($0.identifier, ($0, $0.internedStorage(byteStringArena: byteStringArena, stringArena: stringArena))) })
        let frozenByteStringArena = byteStringArena.freeze()
        let frozenStringArena = stringArena.freeze()
        let internedTasks = tasks.mapValues { taskAndStorage in
            Task(task: taskAndStorage.0, internedStorageHandles: taskAndStorage.1, frozenByteStringArena: frozenByteStringArena, frozenStringArena: frozenStringArena)
        }
        self.init(tasks: internedTasks, llbuildNodeLists: llbuildNodeLists, stringArena: frozenStringArena, byteStringArena: frozenByteStringArena)
    }
}
