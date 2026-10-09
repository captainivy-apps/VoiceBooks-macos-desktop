import Foundation
import Combine

/// Root service container. Owns the database, repositories, TTS engines and
/// the playback engine. Mirrors the Kotlin `AppContainer`.
@MainActor
final class AppServices: ObservableObject {
    let database: AppDatabase
    let fileStorage: FileStorage
    let bookStore: BookStore
    let ttsStore: TtsStore
    let bookRepository: BookRepository
    let ttsRepository: TtsRepository
    let playbackSessionStore: PlaybackSessionStore

    let sherpaEngine = SherpaTtsEngine()
    let sherpaCoordinator: SherpaInitCoordinator
    private let previewEngine = SherpaTtsEngine()
    private let previewCoordinator: SherpaInitCoordinator
    let ttsPreviewController: TtsPreviewController
    let ttsSettingsGate = TtsSettingsGate()
    let playbackEngine: PlaybackEngine

    @Published var startupIssue: StartupIssue?

    init() {
        let root = Paths.appSupport
        do {
            database = try AppDatabase(url: Paths.databaseURL)
        } catch {
            fatalError("Failed to open database: \(error)")
        }
        fileStorage = FileStorage(root: Paths.dataRoot)
        bookStore = BookStore(database: database)
        ttsStore = TtsStore(database: database)
        bookRepository = BookRepository(bookStore: bookStore, fileStorage: fileStorage, cacheDir: Paths.cacheDir)
        ttsRepository = TtsRepository(ttsStore: ttsStore, fileStorage: fileStorage)
        playbackSessionStore = PlaybackSessionStore(rootDir: root)

        sherpaCoordinator = SherpaInitCoordinator(engine: sherpaEngine)
        previewCoordinator = SherpaInitCoordinator(engine: previewEngine)
        ttsPreviewController = TtsPreviewController(engine: previewEngine, coordinator: previewCoordinator)

        playbackEngine = PlaybackEngine(
            bookRepository: bookRepository,
            ttsRepository: ttsRepository,
            sherpaEngine: sherpaEngine,
            sherpaInitCoordinator: sherpaCoordinator,
            playbackSessionStore: playbackSessionStore
        )
    }

    func start() {
        let repository = bookRepository
        let storage = fileStorage
        Task {
            await repository.setImportRunners(
                enqueueImport: { id in
                    Task { await ImportPipeline.runImport(bookRepo: repository, fileStorage: storage, bookId: id) }
                },
                enqueueUrlImport: { id, url in
                    Task { await repository.runUrlImport(bookId: id, url: url) }
                }
            )
        }

        AppSettings.clearSleepTimer()

        Task { [weak self] in
            guard let self else { return }
            do {
                await self.bookRepository.healOversizedBookRows()
            } catch {
                self.report(error)
            }
        }
        Task { [weak self] in
            guard let self else { return }
            await self.ttsRepository.ensureBuiltInModels()
            await self.warmupDefaultEngine()
        }
        playbackEngine.recoverIfNeeded()
    }

    private func warmupDefaultEngine() async {
        guard let model = (try? await ttsRepository.getDefaultModel()) ?? nil,
              model.downloadState == TtsDownloadState.downloaded.rawValue,
              model.localPath != nil else { return }
        let result = await sherpaCoordinator.ensureInitialized(model)
        if result.isSuccess {
            await sherpaCoordinator.withSherpaThreadAsync {
                let speaker = self.sherpaEngine.resolveSpeakerId(model.speakerId)
                _ = self.sherpaEngine.synthesize(text: ".", speed: 1.0, speakerId: speaker)
            }
        }
    }

    func clearStartupIssue() { startupIssue = nil }

    private func report(_ error: Error) {
        if startupIssue == nil {
            startupIssue = StartupIssueClassifier.classify(error)
        }
    }

    func shutdown() {
        playbackEngine.shutdown()
        ttsPreviewController.stopPlayback()
        sherpaCoordinator.shutdown()
        previewCoordinator.shutdown()
    }
}
