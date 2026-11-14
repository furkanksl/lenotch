import AppKit
import Foundation
import Observation
import SwiftUI

struct LauncherApplication: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    var id: URL { url }
}

/// Reads only application bundles, not a Spotlight index or the remote Open/Save panel service.
enum LauncherApplicationCatalog {
    static var roots: [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         URL(fileURLWithPath: "/System/Applications", isDirectory: true),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
    }

    static func scan(roots: [URL]) throws -> [LauncherApplication] {
        var found: [URL: LauncherApplication] = [:]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        for root in roots {
            try Task.checkCancellation()
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                guard let values = try? url.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    if url.pathExtension.lowercased() != "app" { continue }
                } else if values.isDirectory != true { continue }
                if url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                    let data = try? Data(contentsOf: canonical.appendingPathComponent("Contents/Info.plist"))
                    let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                    guard info?["CFBundlePackageType"] as? String == "APPL" else { continue }
                    let fallback = canonical.deletingPathExtension().lastPathComponent
                    let rawName = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? fallback
                    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    found[canonical] = LauncherApplication(url: canonical, name: name.isEmpty ? fallback : name)
                } else if values.isPackage == true || enumerator.level >= 3 {
                    enumerator.skipDescendants()
                }
            }
        }
        return found.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }
}

@MainActor @Observable final class LauncherApplicationPickerModel {
    private(set) var applications: [LauncherApplication] = []
    private(set) var loading = false
    private(set) var error: String?
    var query = ""
    var selected: Set<URL> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    var filtered: [LauncherApplication] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? applications : applications.filter { $0.name.localizedStandardContains(search) }
    }
    var selection: [LauncherApplication] { applications.filter { selected.contains($0.url) } }

    func load(roots: [URL] = LauncherApplicationCatalog.roots) {
        cancel()
        loading = true
        error = nil
        let current = generation
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try LauncherApplicationCatalog.scan(roots: roots) }
            do {
                let apps = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, !Task.isCancelled, generation == current else { return }
                applications = apps
                selected.formIntersection(apps.map(\.url))
                loading = false
                task = nil
            } catch {
                guard let self, generation == current else { return }
                loading = false
                if !(error is CancellationError) { self.error = "Applications couldn’t be loaded. Please try again." }
                task = nil
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        loading = false
    }
}

struct LauncherApplicationPicker: View {
    @Bindable var catalog: LauncherApplicationPickerModel
    let onCancel: () -> Void
    let onAdd: ([LauncherApplication]) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add applications").font(.system(size: 20, weight: .semibold))
            Text("Choose apps to keep in your launcher.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search applications", text: $catalog.query).textFieldStyle(.roundedBorder)
                .focused($searchFocused).accessibilityLabel("Search applications")
            Group {
                if catalog.loading {
                    VStack(spacing: 10) { ProgressView(); Text("Finding applications…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if catalog.filtered.isEmpty {
                    ContentUnavailableView(catalog.error ?? (catalog.query.isEmpty ? "No applications found" : "No matching applications"),
                                           systemImage: "app.dashed", description: Text("Applications are read from the system and your user Applications folders."))
                } else {
                    List(catalog.filtered, selection: $catalog.selected) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 13, weight: .medium))
                                Text(app.url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3).tag(app.url)
                    }
                    .listStyle(.bordered)
                }
            }
            HStack {
                Text("⌘-click to select multiple apps").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(catalog.selection.count > 1 ? "Add \(catalog.selection.count) apps" : "Add") { onAdd(catalog.selection) }
                    .keyboardShortcut(.defaultAction).disabled(catalog.selection.isEmpty || catalog.loading)
            }
        }
        .padding(22).frame(width: 540, height: 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { searchFocused = true }
    }
}
