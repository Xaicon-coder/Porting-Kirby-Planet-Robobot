// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// The user's game library: ROM files in Documents/PlanetPort/games/ plus titles installed from
// CIA files into the emulated SD card. All disk work runs off the main thread.

import Combine
import Foundation
import PlanetCore

@MainActor
final class GameLibrary: ObservableObject {
    static let shared = GameLibrary()

    nonisolated static let supportedExtensions: Set<String> = [
        "3ds", "cci", "cxi", "app", "3dsx", "elf", "axf",
        "zcci", "zcxi", "z3dsx", "bcci", "bcxi",
        "cia", "zcia", "bcia",
    ]
    private nonisolated static let ciaExtensions: Set<String> = ["cia", "zcia", "bcia"]
    private nonisolated static let copyChunkSize = 8 * 1024 * 1024

    /// Sorted: Planet Robobot first, then title.
    @Published private(set) var games: [GameEntry] = []
    /// .cia files found in gamesDirectory, not yet installed.
    @Published private(set) var pendingCIAs: [URL] = []
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage: String?
    /// 0...1 while copying/installing.
    @Published private(set) var progress: Double?
    @Published var alert: AppError?

    /// Documents/PlanetPort/games/
    let gamesDirectory: URL

    var featuredGame: GameEntry? { games.first { $0.isPlanetRobobot } }

    private var refreshGeneration = 0
    /// Invalidates progress reports still in flight from a finished operation.
    private var progressToken = 0

    private struct ScanResult {
        var games: [GameEntry]
        var pendingCIAs: [URL]
    }

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
        gamesDirectory = documents
            .appendingPathComponent("PlanetPort", isDirectory: true)
            .appendingPathComponent("games", isDirectory: true)
    }

    // MARK: - Refresh

    /// Scans gamesDirectory (PPGameInfo per supported file, off the main thread) and
    /// PPEmulator.shared.installedTitles(); updates games / pendingCIAs.
    func refresh() async {
        // PPGameInfo and installedTitles require a prepared bridge.
        guard EmulatorController.shared.isPrepared else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let directory = gamesDirectory
        let result = await Self.performInBackground {
            GameLibrary.scan(directory: directory)
        }
        // A newer refresh started meanwhile: its result wins.
        guard generation == refreshGeneration else { return }
        games = result.games
        pendingCIAs = result.pendingCIAs
    }

    // MARK: - Import

    /// Files picked with .fileImporter (security-scoped). Bootable files are copied into
    /// gamesDirectory (replacing files with the same name); .cia files are installed directly
    /// from the picked URL. Then refresh().
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard !isBusy else {
            alert = AppError(title: "Operazione in corso",
                             message: "Attendi la fine dell'operazione in corso e riprova.")
            return
        }
        if !EmulatorController.shared.isPrepared {
            EmulatorController.shared.bootstrap()
        }

        var failures: [String] = []
        var bootableFiles: [URL] = []
        var ciaFiles: [URL] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if Self.ciaExtensions.contains(ext) {
                ciaFiles.append(url)
            } else if Self.supportedExtensions.contains(ext) {
                bootableFiles.append(url)
            } else {
                failures.append("\(url.lastPathComponent): formato non supportato.")
            }
        }

        isBusy = true
        defer { endBusy() }

        do {
            try FileManager.default.createDirectory(at: gamesDirectory, withIntermediateDirectories: true)
        } catch {
            alert = AppError(title: "Importazione non riuscita", error: error)
            return
        }

        // Copy bootable files.
        let copyCount = Double(bootableFiles.count)
        for (index, source) in bootableFiles.enumerated() {
            busyMessage = "Copia di \(source.lastPathComponent)…"
            progress = Double(index) / copyCount
            let destination = gamesDirectory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            let report = makeProgressReporter(base: Double(index) / copyCount, span: 1 / copyCount)
            let error = await Self.performInBackground {
                GameLibrary.copyFile(from: source, to: destination, progress: report)
            }
            if let error {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Install CIA files.
        for source in ciaFiles {
            guard !EmulatorController.shared.isActive else {
                failures.append("\(source.lastPathComponent): chiudi il gioco in corso prima di installare un CIA.")
                continue
            }
            busyMessage = "Installazione di \(source.lastPathComponent)…"
            progress = 0
            if let error = await installCIA(at: source) {
                failures.append("\(source.lastPathComponent): \(Self.message(for: error))")
            }
        }

        busyMessage = "Aggiornamento della libreria…"
        progress = nil
        await refresh()

        if !failures.isEmpty {
            alert = AppError(title: failures.count == urls.count ? "Importazione non riuscita" : "Importazione incompleta",
                             message: failures.joined(separator: "\n"))
        }
    }

    func installPendingCIA(_ url: URL, deleteAfterInstall: Bool) async {
        guard !isBusy else {
            alert = AppError(title: "Operazione in corso",
                             message: "Attendi la fine dell'operazione in corso e riprova.")
            return
        }
        guard !EmulatorController.shared.isActive else {
            alert = AppError(title: "Gioco in esecuzione",
                             message: "Chiudi il gioco in corso prima di installare un CIA.")
            return
        }

        isBusy = true
        defer { endBusy() }
        busyMessage = "Installazione di \(url.lastPathComponent)…"
        progress = 0

        if let error = await installCIA(at: url) {
            alert = AppError(title: "Installazione non riuscita", error: error)
        } else if deleteAfterInstall {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                alert = AppError(title: "CIA installato",
                                 message: "Il gioco è stato installato, ma non è stato possibile eliminare il file CIA: "
                                    + error.localizedDescription)
            }
        }

        busyMessage = "Aggiornamento della libreria…"
        progress = nil
        await refresh()
    }

    // MARK: - Delete

    /// Deletes a ROM file from gamesDirectory. Installed titles cannot be deleted (alert).
    func delete(_ game: GameEntry) {
        guard !game.isInstalledTitle else {
            alert = AppError(title: "Impossibile eliminare",
                             message: "I giochi installati da un file CIA si trovano nella scheda SD emulata "
                                + "e non possono essere eliminati da qui.")
            return
        }
        guard EmulatorController.shared.currentGame != game else {
            alert = AppError(title: "Gioco in esecuzione",
                             message: "Chiudi il gioco prima di eliminarlo.")
            return
        }
        let gamesPath = gamesDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = game.url.standardizedFileURL.resolvingSymlinksInPath().path
        guard filePath.hasPrefix(gamesPath + "/") else {
            alert = AppError(title: "Impossibile eliminare",
                             message: "Il file non si trova nella cartella dei giochi di PlanetPort.")
            return
        }
        do {
            try FileManager.default.removeItem(at: game.url)
            games.removeAll { $0.id == game.id }
        } catch {
            alert = AppError(title: "Eliminazione non riuscita", error: error)
        }
    }

    // MARK: - Private (main actor)

    private func endBusy() {
        progressToken += 1
        isBusy = false
        busyMessage = nil
        progress = nil
    }

    /// Returns a thread-safe callback that maps a 0...1 fraction of one step onto the overall
    /// progress (base + fraction * span) and publishes it on the main actor.
    private func makeProgressReporter(base: Double, span: Double) -> @Sendable (Double) -> Void {
        progressToken += 1
        let token = progressToken
        // The library is a process-wide singleton, so a strong capture is fine.
        return { fraction in
            Task { @MainActor in
                guard self.progressToken == token, self.isBusy else { return }
                self.progress = min(1, max(0, base + fraction * span))
            }
        }
    }

    /// Installs a CIA through the bridge. iCloud placeholders are first copied to a local
    /// temporary file because the core reads the path directly.
    private func installCIA(at url: URL) async -> Error? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        var installPath = url.path
        var temporaryFolder: URL?
        defer {
            if let temporaryFolder {
                try? FileManager.default.removeItem(at: temporaryFolder)
            }
        }

        if Self.isUbiquitous(url) {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cia-import-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return error
            }
            temporaryFolder = folder
            let localCopy = folder.appendingPathComponent(url.lastPathComponent, isDirectory: false)
            let previousMessage = busyMessage
            busyMessage = "Download di \(url.lastPathComponent)…"
            let report = makeProgressReporter(base: 0, span: 1)
            let copyError = await Self.performInBackground {
                GameLibrary.copyFile(from: url, to: localCopy, progress: report)
            }
            if let copyError { return copyError }
            busyMessage = previousMessage
            installPath = localCopy.path
        }

        // Drop any late copy-progress report before the install reports its own progress.
        progressToken += 1
        progress = 0
        let path = installPath
        return await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            PPEmulator.shared.installCIA(atPath: path, progress: { [weak self] fraction in
                self?.progress = min(1, max(0, fraction))
            }, completion: { error in
                continuation.resume(returning: error)
            })
        }
    }

    /// Runs `work` on a global queue and resumes the caller with its result.
    private static func performInBackground<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func message(for error: Error) -> String {
        let nsError = error as NSError
        var text = nsError.localizedDescription
        if let details = nsError.userInfo[PPErrorCoreDetailsKey] as? String, !details.isEmpty {
            text += " (\(details))"
        }
        return text
    }

    // MARK: - Background work (nonisolated)

    private nonisolated static func scan(directory: URL) -> ScanResult {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var games: [GameEntry] = []
        var pendingCIAs: [URL] = []
        var seenPaths = Set<String>()

        let keys: [URLResourceKey] = [.isRegularFileKey]
        if let enumerator = fileManager.enumerator(at: directory,
                                                   includingPropertiesForKeys: keys,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                guard supportedExtensions.contains(ext) else { continue }
                guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
                if ciaExtensions.contains(ext) {
                    pendingCIAs.append(url)
                    continue
                }
                // Files that cannot be identified at all are skipped; encrypted ones are listed.
                guard let info = try? PPGameInfo(atPath: url.path) else { continue }
                let entry = GameEntry(info: info)
                if seenPaths.insert(entry.id).inserted {
                    games.append(entry)
                }
            }
        }

        for info in PPEmulator.shared.installedTitles() {
            let entry = GameEntry(info: info)
            if seenPaths.insert(entry.id).inserted {
                games.append(entry)
            }
        }

        games.sort(by: areInLibraryOrder)
        pendingCIAs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return ScanResult(games: games, pendingCIAs: pendingCIAs)
    }

    /// Planet Robobot first, then title, then installed titles before files, then path.
    private nonisolated static func areInLibraryOrder(_ lhs: GameEntry, _ rhs: GameEntry) -> Bool {
        if lhs.isPlanetRobobot != rhs.isPlanetRobobot {
            return lhs.isPlanetRobobot
        }
        let order = lhs.title.localizedStandardCompare(rhs.title)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        if lhs.isInstalledTitle != rhs.isInstalledTitle {
            return lhs.isInstalledTitle
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// Copies a (security-scoped) file into `destination`, replacing an existing file. Returns
    /// nil on success. Uses file coordination so iCloud files are downloaded first.
    private nonisolated static func copyFile(from source: URL, to destination: URL,
                                             progress: @escaping @Sendable (Double) -> Void) -> Error? {
        let accessing = source.startAccessingSecurityScopedResource()
        defer {
            if accessing { source.stopAccessingSecurityScopedResource() }
        }

        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
        if sourcePath == destinationPath {
            // Picked from PlanetPort's own games folder: already in place.
            progress(1)
            return nil
        }

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [],
                                                         error: &coordinationError) { readableURL in
            do {
                try chunkedCopy(from: readableURL, to: destination, progress: progress)
            } catch {
                copyError = error
            }
        }
        return copyError ?? coordinationError
    }

    /// Streams the file in chunks into a temporary sibling, then atomically moves it in place.
    private nonisolated static func chunkedCopy(from source: URL, to destination: URL,
                                                progress: (Double) -> Void) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial", isDirectory: false)
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        var completed = false
        defer {
            if !completed { try? fileManager.removeItem(at: temporary) }
        }

        let totalBytes = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)

        var copiedBytes: Int64 = 0
        var lastReported = -1.0
        do {
            while true {
                let chunk: Data? = try autoreleasepool {
                    try input.read(upToCount: copyChunkSize)
                }
                guard let chunk, !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                copiedBytes += Int64(chunk.count)
                if totalBytes > 0 {
                    let fraction = min(1, Double(copiedBytes) / Double(totalBytes))
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress(fraction)
                    }
                }
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        completed = true
        progress(1)
    }
}
