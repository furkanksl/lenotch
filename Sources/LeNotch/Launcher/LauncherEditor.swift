import AppKit
import SwiftUI

/// A regular key window gives the native pickers and URL fields normal keyboard/paste
/// behavior without making the nonactivating notch panel responsible for text editing.
@MainActor final class LauncherEditor {
    static let shared = LauncherEditor()
    private var window: NSWindow?
    private var applicationSheet: NSWindow?
    private var applicationCatalog: LauncherApplicationPickerModel?

    func show(model: LauncherModel = .shared) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 550),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Launcher — LeNotch"
            window.minSize = NSSize(width: 540, height: 420)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: LauncherEditorView(
            model: model,
            onAddApplication: { [weak self] in self?.chooseApplications(model: model) },
            onAddFolder: { [weak self] in self?.chooseFolders(model: model) },
            onDone: { [weak self] in self?.window?.close() }
        ))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func chooseApplications(model: LauncherModel, roots: [URL] = LauncherApplicationCatalog.roots) {
        guard let window, window.attachedSheet == nil, applicationSheet == nil else { return }
        let catalog = LauncherApplicationPickerModel()
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = "Add applications"
        sheet.contentView = NSHostingView(rootView: LauncherApplicationPicker(
            catalog: catalog,
            onCancel: { [weak self] in self?.closeApplicationPicker() },
            onAdd: { [weak self] applications in
                var failures: [String] = []
                for app in applications {
                    do { try model.add(url: app.url) }
                    catch { failures.append("\(app.name): \(error.localizedDescription)") }
                }
                self?.closeApplicationPicker()
                if !failures.isEmpty { self?.showFailures(failures, for: window) }
            }
        ))
        applicationSheet = sheet
        applicationCatalog = catalog
        window.beginSheet(sheet) { [weak self] _ in
            catalog.cancel()
            sheet.orderOut(nil)
            self?.applicationSheet = nil
            self?.applicationCatalog = nil
        }
        catalog.load(roots: roots)
    }

    func closeApplicationPicker() {
        guard let applicationSheet else { return }
        applicationCatalog?.cancel()
        window?.endSheet(applicationSheet)
    }

    private func showFailures(_ failures: [String], for window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = "Some items could not be added"
        alert.informativeText = failures.prefix(4).joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func chooseFolders(model: LauncherModel) {
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Add folders to Launcher"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            var failures: [String] = []
            for url in panel.urls {
                do { try model.add(url: url) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            guard !failures.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Some items could not be added"
            alert.informativeText = failures.prefix(4).joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }
}

struct LauncherEditorView: View {
    let model: LauncherModel
    let onAddApplication: () -> Void
    let onAddFolder: () -> Void
    let onDone: () -> Void
    @State private var addingLink = false
    @State private var selectedID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Launcher").font(.system(size: 24, weight: .semibold))
                    Text("Apps, folders, and links within reach.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Application…", systemImage: "app", action: onAddApplication)
                    Button("Folder…", systemImage: "folder", action: onAddFolder)
                    Button("Website…", systemImage: "link") { addingLink = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .disabled(model.items.count >= LauncherModel.maximumItems)
                .accessibilityLabel("Add Launcher item")
            }

            if model.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("Your Launcher is empty").font(.system(size: 16, weight: .medium))
                    Text("Add an application, a folder, or a website.\nNothing is added automatically.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("Add application…", action: onAddApplication)
                        Button("Add website…") { addingLink = true }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
            } else {
                List(selection: $selectedID) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        LauncherEditorRow(model: model, item: item, index: index,
                                          onError: { errorMessage = $0 })
                            .tag(item.id).listRowSeparator(.hidden)
                            .padding(.vertical, 4)
                    }
                    .onMove { model.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Configured Launcher items")
            }

            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.items.count) of \(LauncherModel.maximumItems) items · Saved on this Mac")
                    Text("Use the arrows or drag rows to reorder. Press Return to save a name.")
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $addingLink) {
            LauncherLinkEditor(model: model) { addingLink = false }
        }
        .alert("Could not update Launcher", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct LauncherEditorRow: View {
    let model: LauncherModel
    let item: LauncherItem
    let index: Int
    let onError: (String) -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = model.icon(for: item) {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else { Image(systemName: item.kind.symbol).resizable().scaledToFit() }
            }
            .frame(width: 32, height: 32).accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $name).textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityLabel("Name for \(item.title)")
                    .onSubmit {
                        do { try model.rename(item.id, title: name); name = model.items.first { $0.id == item.id }?.title ?? name }
                        catch { onError(error.localizedDescription); name = item.title }
                    }
                Text(item.url.isFileURL ? item.url.path : item.url.absoluteString)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                rowButton("chevron.up", label: "Move \(item.title) earlier", disabled: index == 0) {
                    model.move(item.id, by: -1)
                }
                rowButton("chevron.down", label: "Move \(item.title) later", disabled: index + 1 == model.items.count) {
                    model.move(item.id, by: 1)
                }
                rowButton("minus", label: "Remove \(item.title)") { model.remove(item.id) }
            }
        }
        .onAppear { name = item.title }
        .onChange(of: item.title) { _, value in name = value }
    }

    private func rowButton(_ symbol: String, label: String, disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).frame(width: 26, height: 28)
        }
        .buttonStyle(.borderless).disabled(disabled).help(label).accessibilityLabel(label)
    }
}

private struct LauncherLinkEditor: View {
    let model: LauncherModel
    let onClose: () -> Void
    @State private var address = ""
    @State private var name = ""
    @State private var error: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a website").font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Address").font(.system(size: 12, weight: .medium))
                TextField("https://example.com", text: $address)
                    .textFieldStyle(.roundedBorder).focused($addressFocused)
                    .accessibilityLabel("Website address").onSubmit(add)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name (optional)").font(.system(size: 12, weight: .medium))
                TextField("Use the website name", text: $name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Website name").onSubmit(add)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Only http and https links are supported.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { addressFocused = true }
    }

    private func add() {
        do { try model.addLink(address, title: name); onClose() }
        catch { self.error = error.localizedDescription }
    }
}
