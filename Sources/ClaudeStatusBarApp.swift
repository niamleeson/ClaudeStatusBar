import SwiftUI

@main
struct ClaudeStatusBarApp: App {
    @StateObject private var monitor = ClaudeMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: monitor.iconName)
                .symbolRenderingMode(.hierarchical)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: ClaudeMonitor

    var body: some View {
        if monitor.instances.isEmpty {
            Text("No Claude Code instances")
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            ForEach(monitor.instances) { instance in
                let dot = instance.isActive ? "●" : "○"
                let status = instance.isActive ? "Working" : "Idle"
                let dir = instance.cwd.replacingOccurrences(of: home, with: "~")
                Text("\(dot)  \(dir)  —  \(status)")
            }
            Divider()
            Text("\(monitor.activeCount) active, \(monitor.instances.count - monitor.activeCount) idle")
        }
        Divider()
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
