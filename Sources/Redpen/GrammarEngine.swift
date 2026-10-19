import CryptoKit
import Foundation
import RedpenCore

/// The full grammar engine (LanguageTool) without Homebrew: on request, Redpen downloads LanguageTool and a Java
/// runtime (about 300 MB) into Application Support and runs it itself on port 8081 while Redpen is open.
/// A LanguageTool that is already running, such as a Homebrew one, is used as is and never touched.
@MainActor
final class GrammarEngine: ObservableObject {
    static let shared = GrammarEngine()

    enum State: Equatable { case checking, running, starting, missing, downloading(Double), failed(String) }
    @Published private(set) var state: State = .checking

    /// Exact versions with known SHA-256 fingerprints. A file that doesn't match is thrown away, never unpacked or run.
    /// Java's fingerprint is the one Adoptium publishes; LanguageTool publishes none, so its fingerprint was taken
    /// from languagetool.org on 2026-10-16. Moving to a newer version means updating both lines.
    struct Pinned { let url: URL; let sha256: String }
    static let languageTool = Pinned(url: URL(string: "https://languagetool.org/download/LanguageTool-6.6.zip")!,
                                     sha256: "53600506b399bb5ffe1e4c8dec794fd378212f14aaf38ccef9b6f89314d11631")
    static var java: Pinned {
        let base = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/"
        #if arch(arm64)
        return Pinned(url: URL(string: base + "OpenJDK21U-jre_aarch64_mac_hotspot_21.0.12.1_1.tar.gz")!,
                      sha256: "dec50fc6f9fcd4fe3ae8cabf5a5fa68f6afc48841f7698e468e9aa5d54beed84")
        #else
        return Pinned(url: URL(string: base + "OpenJDK21U-jre_x64_mac_hotspot_21.0.12.1_1.tar.gz")!,
                      sha256: "6717ec641fd9ce0bb209ca083ee23b42202ac68cb6fcc5753496e0e4a0f41989")
        #endif
    }

    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Redpen/engine")
    private var server: Process?

    /// Called at launch: uses a running engine, starts an installed one, or reports it missing.
    func startIfInstalled() {
        Task {
            if await LanguageTool.isRunning() { state = .running; return }
            guard serverJar != nil, java != nil else { state = .missing; return }
            launch()
        }
    }

    func install() {
        guard state == .missing || { if case .failed = state { return true } else { return false } }() else { return }
        state = .downloading(0)
        let dir = self.dir
        Task.detached {
            do {
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                // Two files, about 50 MB and 250 MB; progress counts both as one bar.
                let jre = try await GrammarEngine.download(GrammarEngine.java) { f in await GrammarEngine.shared.progress(f * 0.16) }
                try GrammarEngine.unpack(jre, into: dir.appendingPathComponent("java"), tar: true)
                let lt = try await GrammarEngine.download(GrammarEngine.languageTool) { f in await GrammarEngine.shared.progress(0.16 + f * 0.84) }
                try GrammarEngine.unpack(lt, into: dir.appendingPathComponent("languagetool"), tar: false)
                await MainActor.run { GrammarEngine.shared.launch() }
            } catch {
                Log.note("grammar engine install failed: \(error.localizedDescription)")
                await MainActor.run { GrammarEngine.shared.state = .failed("Download didn\u{2019}t finish. Check the connection and try again.") }
            }
        }
    }

    private func progress(_ f: Double) { state = .downloading(min(max(f, 0), 1)) }

    /// Runs the downloaded LanguageTool on port 8081 and waits for it to answer.
    private func launch() {
        guard let jar = serverJar, let java else { state = .missing; return }
        state = .starting
        let p = Process()
        p.executableURL = java
        p.arguments = ["-Xmx1g", "-cp", jar.path, "org.languagetool.server.HTTPServer", "--port", "8081"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            state = .failed("The grammar engine wouldn\u{2019}t start.")
            Log.note("grammar engine start failed: \(error.localizedDescription)")
            return
        }
        server = p
        Log.note("grammar engine starting from \(dir.path)")
        Task {
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                if await LanguageTool.isRunning() {
                    await GrammarEngine.warmUp()
                    state = .running; Log.note("grammar engine running"); return
                }
                if !p.isRunning { break }
            }
            state = .failed("The grammar engine wouldn\u{2019}t start.")
            Log.note("grammar engine did not answer on port 8081")
        }
    }

    /// The first check after a start takes about four seconds while LanguageTool loads its rules; run it here,
    /// so a real check never hits Redpen's short time limit.
    nonisolated static func warmUp() async {
        guard LanguageTool.listenerIsMine(fresh: true) else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8081/v2/check")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("language=en-CA&text=This%20is%20a%20test.".utf8)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Stops the engine Redpen started. One started by someone else keeps running.
    func stop() { server?.terminate() }

    // MARK: Files

    private var serverJar: URL? { find("languagetool-server.jar", under: dir.appendingPathComponent("languagetool"), depth: 2) }
    private var java: URL? { find("java", under: dir.appendingPathComponent("java"), depth: 5, executable: true) }

    private func find(_ name: String, under root: URL, depth: Int, executable: Bool = false) -> URL? {
        let fm = FileManager.default
        guard depth >= 0, let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        if let hit = items.first(where: { $0.lastPathComponent == name && (!executable || fm.isExecutableFile(atPath: $0.path)) }) { return hit }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let hit = find(name, under: item, depth: depth - 1, executable: executable) { return hit }
        }
        return nil
    }

    nonisolated static func download(_ pin: Pinned, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        let watch = ProgressWatch { f in Task { await progress(f) } }
        let (tmp, response) = try await URLSession.shared.download(from: pin.url, delegate: watch)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: tmp, to: file)
        guard try sha256(of: file) == pin.sha256 else {
            try? FileManager.default.removeItem(at: file)
            Log.note("grammar engine download did not match its fingerprint: \(pin.url.lastPathComponent)")
            throw URLError(.cannotDecodeContentData)
        }
        await progress(1)
        return file
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks with the Mac's own tools, arguments only, never a shell.
    nonisolated static func unpack(_ archive: URL, into dest: URL, tar: Bool) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tar ? "/usr/bin/tar" : "/usr/bin/ditto")
        p.arguments = tar ? ["-xzf", archive.path, "-C", dest.path] : ["-x", "-k", archive.path, dest.path]
        try p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: archive)
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
}

/// Reports a download's progress, at most once per percent.
private final class ProgressWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    private var watch: NSKeyValueObservation?
    private var last = 0.0
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        watch = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            guard let self, p.fractionCompleted - self.last >= 0.01 else { return }
            self.last = p.fractionCompleted
            self.report(p.fractionCompleted)
        }
    }
}
