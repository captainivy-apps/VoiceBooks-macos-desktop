import Foundation

/// Actor-confined data access for TTS models and benchmarks.
actor TtsStore {
    private let db: AppDatabase
    private var sqlite: SQLiteDatabase { db.sqlite }

    init(database: AppDatabase) {
        self.db = database
    }

    func models() throws -> [TtsModelEntity] {
        var result: [TtsModelEntity] = []
        try sqlite.query("SELECT \(Self.columns) FROM tts_models ORDER BY name ASC") { row in
            result.append(Self.mapModel(row))
        }
        return result
    }

    func getModel(_ id: String) throws -> TtsModelEntity? {
        try sqlite.queryValue("SELECT \(Self.columns) FROM tts_models WHERE id = ?", [.text(id)]) {
            Self.mapModel($0)
        }
    }

    func getDefaultModel() throws -> TtsModelEntity? {
        try sqlite.queryValue("SELECT \(Self.columns) FROM tts_models WHERE isDefault = 1 LIMIT 1") {
            Self.mapModel($0)
        }
    }

    func upsert(_ model: TtsModelEntity) throws {
        try sqlite.run("""
        INSERT OR REPLACE INTO tts_models
        (id, name, language, sizeBytes, downloadUrl, localPath, downloadState, downloadError, isDefault, modelType, speakerId)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(model.id), .text(model.name), .text(model.language), .integer(model.sizeBytes),
            .text(model.downloadUrl), model.localPath.map { .text($0) } ?? .null,
            .text(model.downloadState), model.downloadError.map { .text($0) } ?? .null,
            .integer(model.isDefault ? 1 : 0), .text(model.modelType), .integer(Int64(model.speakerId)),
        ])
    }

    func upsertAll(_ models: [TtsModelEntity]) throws {
        for model in models { try upsert(model) }
    }

    func clearDefault() throws {
        try sqlite.run("UPDATE tts_models SET isDefault = 0")
    }

    func setDefault(_ id: String) throws {
        try sqlite.run("UPDATE tts_models SET isDefault = 1 WHERE id = ?", [.text(id)])
    }

    func updateSpeakerId(_ id: String, speakerId: Int) throws {
        try sqlite.run("UPDATE tts_models SET speakerId = ? WHERE id = ?", [.integer(Int64(speakerId)), .text(id)])
    }

    func updateDownloadState(_ id: String, state: TtsDownloadState, localPath: String?, error: String?) throws {
        try sqlite.run(
            "UPDATE tts_models SET downloadState = ?, localPath = ?, downloadError = ? WHERE id = ?",
            [.text(state.rawValue), localPath.map { .text($0) } ?? .null,
             error.map { .text($0) } ?? .null, .text(id)]
        )
    }

    func deleteModel(_ id: String) throws {
        try sqlite.run("DELETE FROM tts_models WHERE id = ?", [.text(id)])
    }

    // MARK: - Benchmarks

    func benchmarks() throws -> [TtsModelBenchmarkEntity] {
        var result: [TtsModelBenchmarkEntity] = []
        try sqlite.query("SELECT modelId, speakerId, synthesisMs, audioDurationMs, rtf, sampleRate, benchmarkedAt FROM tts_model_benchmarks") { row in
            result.append(TtsModelBenchmarkEntity(
                modelId: row.string(0), speakerId: row.int(1), synthesisMs: row.int64(2),
                audioDurationMs: row.int64(3), rtf: Float(row.double(4)),
                sampleRate: row.int(5), benchmarkedAt: row.int64(6)
            ))
        }
        return result
    }

    func upsertBenchmark(_ benchmark: TtsModelBenchmarkEntity) throws {
        try sqlite.run("""
        INSERT OR REPLACE INTO tts_model_benchmarks
        (modelId, speakerId, synthesisMs, audioDurationMs, rtf, sampleRate, benchmarkedAt)
        VALUES (?,?,?,?,?,?,?)
        """, [
            .text(benchmark.modelId), .integer(Int64(benchmark.speakerId)),
            .integer(benchmark.synthesisMs), .integer(benchmark.audioDurationMs),
            .real(Double(benchmark.rtf)), .integer(Int64(benchmark.sampleRate)),
            .integer(benchmark.benchmarkedAt),
        ])
    }

    func getBenchmark(_ modelId: String, speakerId: Int) throws -> TtsModelBenchmarkEntity? {
        try sqlite.queryValue(
            "SELECT modelId, speakerId, synthesisMs, audioDurationMs, rtf, sampleRate, benchmarkedAt FROM tts_model_benchmarks WHERE modelId = ? AND speakerId = ? LIMIT 1",
            [.text(modelId), .integer(Int64(speakerId))]
        ) { row in
            TtsModelBenchmarkEntity(
                modelId: row.string(0), speakerId: row.int(1), synthesisMs: row.int64(2),
                audioDurationMs: row.int64(3), rtf: Float(row.double(4)),
                sampleRate: row.int(5), benchmarkedAt: row.int64(6)
            )
        }
    }

    private static let columns =
        "id, name, language, sizeBytes, downloadUrl, localPath, downloadState, downloadError, isDefault, modelType, speakerId"

    private static func mapModel(_ row: SQLiteRow) -> TtsModelEntity {
        TtsModelEntity(
            id: row.string(0), name: row.string(1), language: row.string(2),
            sizeBytes: row.int64(3), downloadUrl: row.string(4), localPath: row.optionalString(5),
            downloadState: row.string(6), downloadError: row.optionalString(7),
            isDefault: row.bool(8), modelType: row.string(9), speakerId: row.int(10)
        )
    }
}
