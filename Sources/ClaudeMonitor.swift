import Foundation
import Combine
import CoreServices

struct ClaudeInstance: Identifiable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let isActive: Bool
    var id: Int32 { pid }
}

@MainActor
class ClaudeMonitor: ObservableObject {
    @Published var instances: [ClaudeInstance] = []

    private let activityThreshold: TimeInterval = 3.0
    private var idleTimer: Timer?
    private var fsEventStream: FSEventStreamRef?

    private let sessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }()

    private let projectsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }()

    var activeCount: Int {
        instances.filter(\.isActive).count
    }

    var anyActive: Bool {
        activeCount > 0
    }

    var iconName: String {
        if instances.isEmpty {
            return "brain"
        } else if anyActive {
            return "brain.head.profile.fill"
        } else {
            return "brain.head.profile"
        }
    }

    init() {
        refresh()
        startFSEvents()
    }

    deinit {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        idleTimer?.invalidate()
    }

    // MARK: - FSEvents

    private func startFSEvents() {
        let paths = [sessionsDir.path, projectsDir.path] as CFArray

        var context = FSEventStreamContext()
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<ClaudeMonitor>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                monitor.refresh()
            }
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,          // 500ms latency — coalesces rapid writes
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    // MARK: - Idle transition timer

    /// Starts a short timer to detect when active instances go idle.
    /// Only runs while there are active instances.
    private func updateIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil

        if anyActive {
            idleTimer = Timer.scheduledTimer(withTimeInterval: activityThreshold + 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    // MARK: - Refresh

    func refresh() {
        let fm = FileManager.default
        guard let sessionFiles = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else {
            instances = []
            updateIdleTimer()
            return
        }

        var found: [ClaudeInstance] = []

        for file in sessionFiles where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = json["pid"] as? Int32,
                  let sessionId = json["sessionId"] as? String,
                  let cwd = json["cwd"] as? String
            else { continue }

            guard kill(pid, 0) == 0 else { continue }

            let encodedCwd = cwd.replacingOccurrences(of: "/", with: "-")
            let jsonlPath = projectsDir
                .appendingPathComponent(encodedCwd)
                .appendingPathComponent("\(sessionId).jsonl")

            var isActive = false
            if let attrs = try? fm.attributesOfItem(atPath: jsonlPath.path),
               let modDate = attrs[.modificationDate] as? Date {
                isActive = Date().timeIntervalSince(modDate) < activityThreshold
            }

            found.append(ClaudeInstance(
                pid: pid,
                sessionId: sessionId,
                cwd: cwd,
                isActive: isActive
            ))
        }

        instances = found.sorted { $0.pid < $1.pid }
        updateIdleTimer()
    }
}
