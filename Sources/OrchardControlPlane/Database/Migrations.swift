import Fluent

struct CreateDeviceTablesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(DeviceModel.schema)
            .field("device_id", .string, .identifier(auto: false))
            .field("name", .string, .required)
            .field("host_name", .string, .required)
            .field("platform", .string, .required)
            .field("capabilities_json", .string, .required)
            .field("max_parallel_tasks", .int, .required)
            .field("metrics_json", .string, .required)
            .field("registered_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .create()

        try await database.schema(DeviceWorkspaceModel.schema)
            .id()
            .field("device_id", .string, .required)
            .field("workspace_id", .string, .required)
            .field("name", .string, .required)
            .field("root_path", .string, .required)
            .foreignKey("device_id", references: DeviceModel.schema, "device_id", onDelete: .cascade)
            .unique(on: "device_id", "workspace_id")
            .create()

        try await database.schema(TaskModel.schema)
            .field("task_id", .string, .identifier(auto: false))
            .field("title", .string, .required)
            .field("kind", .string, .required)
            .field("workspace_id", .string, .required)
            .field("relative_path", .string)
            .field("priority", .string, .required)
            .field("status", .string, .required)
            .field("payload_json", .string, .required)
            .field("preferred_device_id", .string)
            .field("assigned_device_id", .string)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("started_at", .datetime)
            .field("finished_at", .datetime)
            .field("stop_requested_at", .datetime)
            .field("exit_code", .int)
            .field("summary", .string)
            .create()

        try await database.schema(TaskLogModel.schema)
            .id()
            .field("task_id", .string, .required)
            .field("device_id", .string, .required)
            .field("created_at", .datetime, .required)
            .field("line", .string, .required)
            .foreignKey("task_id", references: TaskModel.schema, "task_id", onDelete: .cascade)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(TaskLogModel.schema).delete()
        try await database.schema(TaskModel.schema).delete()
        try await database.schema(DeviceWorkspaceModel.schema).delete()
        try await database.schema(DeviceModel.schema).delete()
    }
}

struct AddTaskLogSequenceMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(TaskLogModel.schema)
            .field("sequence", .int)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(TaskLogModel.schema)
            .deleteField("sequence")
            .update()
    }
}

struct CreateManagedRunTablesMigration: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ManagedRunModel.schema)
            .field("run_id", .string, .identifier(auto: false))
            .field("task_id", .string)
            .field("device_id", .string)
            .field("title", .string, .required)
            .field("driver", .string, .required)
            .field("workspace_id", .string, .required)
            .field("relative_path", .string)
            .field("prompt", .string, .required)
            .field("cwd", .string)
            .field("status", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("started_at", .datetime)
            .field("ended_at", .datetime)
            .field("exit_code", .int)
            .field("summary", .string)
            .field("pid", .int)
            .field("last_heartbeat_at", .datetime)
            .field("codex_session_id", .string)
            .field("last_user_prompt", .string)
            .field("last_assistant_preview", .string)
            .unique(on: "task_id")
            .create()

        try await database.schema(ManagedRunEventModel.schema)
            .id()
            .field("run_id", .string, .required)
            .field("kind", .string, .required)
            .field("created_at", .datetime, .required)
            .field("title", .string, .required)
            .field("message", .string)
            .foreignKey("run_id", references: ManagedRunModel.schema, "run_id", onDelete: .cascade)
            .create()

        try await database.schema(ManagedRunLogModel.schema)
            .id()
            .field("run_id", .string, .required)
            .field("device_id", .string, .required)
            .field("created_at", .datetime, .required)
            .field("sequence", .int)
            .field("line", .string, .required)
            .foreignKey("run_id", references: ManagedRunModel.schema, "run_id", onDelete: .cascade)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ManagedRunLogModel.schema).delete()
        try await database.schema(ManagedRunEventModel.schema).delete()
        try await database.schema(ManagedRunModel.schema).delete()
    }
}
