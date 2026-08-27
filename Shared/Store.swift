import Foundation

/// Persists the last known state to ~/Library/Application Support/ClaudeCodeUsage/state.json
/// so the app and the widget extension (both unsandboxed) share one source of truth.
enum Store {
    /// The real user home, even inside the widget's sandbox (where
    /// homeDirectoryForCurrentUser points at the container instead).
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Shared between the (unsandboxed) app and the sandboxed widget.
    /// An app-group container would be the textbook choice, but ~/Library/Group
    /// Containers is managed by containermanagerd and won't hand out a group we
    /// can't own without a Team ID, so the widget reaches this folder through a
    /// sandbox temporary exception instead.
    static var directory: URL {
        realHome.appendingPathComponent("Library/Application Support/ClaudeCodeUsage", isDirectory: true)
    }
    static var stateURL: URL { directory.appendingPathComponent("state.json") }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (enc, dec)
    }

    static func load() -> StoreState {
        let (_, dec) = coder()
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? dec.decode(StoreState.self, from: data) else { return StoreState() }
        return state
    }

    /// Set when the last save failed, so the UI can say so instead of
    /// silently showing state that was never persisted.
    private(set) static var lastSaveError: String?

    static func save(_ state: StoreState) {
        do {
            let (enc, _) = coder()
            let data = try enc.encode(state)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: stateURL, options: .atomic)
            lastSaveError = nil
        } catch {
            lastSaveError = error.localizedDescription
        }
    }

    // MARK: Widget heartbeat — lets the companion app confirm the widget
    // extension is actually being run by the system.

    static var heartbeatURL: URL { directory.appendingPathComponent("widget-heartbeat") }

    static func recordWidgetHeartbeat() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? ISO8601DateFormatter().string(from: Date()).data(using: .utf8)?.write(to: heartbeatURL, options: .atomic)
    }

    /// Records widget-extension lifecycle stages for troubleshooting — the only
    /// window into a process macOS launches on its own schedule.
    static func trace(_ stage: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(stage)\n"
        let url = directory.appendingPathComponent("widget-trace.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 32_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }

    static func lastWidgetHeartbeat() -> Date? {
        guard let s = try? String(contentsOf: heartbeatURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
