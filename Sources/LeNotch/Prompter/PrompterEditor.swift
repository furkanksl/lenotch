import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A regular key window keeps editing, paste, selection, and undo out of the notch panel.
@MainActor final class PrompterEditor {
    private var window: NSWindow?

    func show(model: PrompterModel, onStart: @escaping @MainActor () -> Void) {
        model.pause()
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Prompter — LeNotch"
            window.minSize = NSSize(width: 680, height: 460)
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.center()
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: PrompterEditorView(
            model: model,
            onImport: { [weak self] in self?.importText(model: model) },
            onStart: { [weak self] in self?.window?.orderOut(nil); onStart() }
        ).preferredColorScheme(.dark))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func importText(model: PrompterModel) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Import a script"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else {
                    self?.showImportError("Choose a text file smaller than 2 MB.")
                    return
                }
                var encoding = String.Encoding.utf8
                let text = try String(contentsOf: url, usedEncoding: &encoding)
                model.importText(text, title: url.deletingPathExtension().lastPathComponent)
            } catch {
                self?.showImportError("The file could not be read as plain text. Try saving it as a UTF-8 .txt file.")
            }
        }
    }

    private func showImportError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not import script"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

private struct PrompterEditorView: View {
    let model: PrompterModel
    let onImport: () -> Void
    let onStart: () -> Void
    @State private var deletingID: UUID?
    @State private var confirmDelete = false

    private var wordCount: Int { model.text.split(whereSeparator: \.isWhitespace).count }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 182)
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your script").font(.system(size: 20, weight: .semibold))
                        Text("Keep your eyes near the camera.")
                            .font(.system(size: 12)).foregroundStyle(IslandColor.secondary)
                    }
                    Spacer(minLength: 4)
                    Text("Saved on this Mac").font(.system(size: 10))
                        .foregroundStyle(IslandColor.secondary)
                }

                if model.selectedScript != nil {
                    scriptEditor
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.badge.plus").font(.system(size: 32, weight: .light))
                            .foregroundStyle(IslandColor.secondary)
                        Text("Write your first script").font(.system(size: 17, weight: .medium))
                        Text("Add your words, then start reading below the camera.")
                            .font(.system(size: 12)).foregroundStyle(IslandColor.secondary)
                            .multilineTextAlignment(.center)
                        Button("New script") { model.addScript() }
                            .buttonStyle(PrompterEditorButtonStyle(prominent: false))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                settings

                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(IslandColor.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Text("Scripts save automatically. No microphone needed.")
                        .font(.system(size: 10)).foregroundStyle(IslandColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: onStart) {
                        Label("Start reading", systemImage: "play.fill")
                    }
                    .buttonStyle(PrompterEditorButtonStyle(prominent: true))
                    .disabled(!model.canPlay)
                    .help("Open the script in the notch")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .foregroundStyle(.white)
        .alert("Delete this script?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                if let deletingID { model.deleteScript(deletingID) }
                deletingID = nil
            }
            Button("Cancel", role: .cancel) { deletingID = nil }
        } message: {
            Text("This removes the saved script from this Mac. This cannot be undone.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Scripts").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.addScript() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26).background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain).help("New script").accessibilityLabel("New script")
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.scripts) { script in
                        Button { model.selectScript(script.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(script.title.isEmpty ? "Untitled script" : script.title)
                                    .font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    .foregroundStyle(.white)
                                let words = script.text.split(whereSeparator: \.isWhitespace).count
                                Text("\(words) \(words == 1 ? "word" : "words")")
                                    .font(.system(size: 10)).foregroundStyle(IslandColor.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(model.selectedID == script.id ? 0.12 : 0)))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.selectedID == script.id ? .isSelected : [])
                        .contextMenu {
                            Button("Delete script", role: .destructive) { requestDelete(script.id) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Button(action: onImport) { Label("Import text…", systemImage: "square.and.arrow.down") }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(IslandColor.secondary)
                .help("Import a plain-text .txt script")
            Button(role: .destructive) {
                if let script = model.selectedScript { requestDelete(script.id) }
            } label: {
                Label("Delete script", systemImage: "trash")
            }
            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(IslandColor.secondary)
            .disabled(model.selectedScript == nil)
        }
        .padding(16)
        .frame(maxHeight: .infinity)
        .background(.white.opacity(0.035))
    }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Script title", text: Binding(
                get: { model.selectedScript?.title ?? "" }, set: { model.updateScript(title: $0) }
            ))
            .textFieldStyle(.plain).font(.system(size: 17, weight: .semibold))
            .accessibilityLabel("Script title")
            Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            TextEditor(text: Binding(
                get: { model.text }, set: { model.updateScript(text: $0) }
            ))
            .font(.system(size: 16))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.035)))
            .accessibilityLabel("Script text")
            .id(model.selectedID)
            HStack {
                Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
                Spacer()
                Text("Plain text")
            }
            .font(.system(size: 10)).foregroundStyle(IslandColor.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    private var settings: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                settingSlider("Scroll speed", value: Binding(get: { model.speed }, set: { model.speed = $0 }),
                              range: 5...120, step: 5, suffix: "pt/s")
                settingSlider("Text size", value: Binding(get: { model.fontSize }, set: { model.fontSize = $0 }),
                              range: 16...48, step: 2, suffix: "pt")
            }
            HStack(spacing: 20) {
                Toggle("3-second countdown", isOn: Binding(
                    get: { model.countdownEnabled }, set: { model.countdownEnabled = $0 }
                ))
                Toggle("Mirror text", isOn: Binding(get: { model.mirrored }, set: { model.mirrored = $0 }))
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox).font(.system(size: 11)).tint(IslandColor.green)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }

    private func settingSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                               step: Double, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(IslandColor.secondary)
                Spacer(minLength: 2)
                Text("\(Int(value.wrappedValue.rounded())) \(suffix)").monospacedDigit()
            }
            .font(.system(size: 11))
            Slider(value: value, in: range, step: step).tint(IslandColor.green)
                .accessibilityLabel(label)
                .accessibilityValue("\(Int(value.wrappedValue.rounded())) \(suffix)")
        }
    }

    private func requestDelete(_ id: UUID) {
        deletingID = id
        confirmDelete = true
    }
}

private struct PrompterEditorButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? .black : .white)
            .padding(.horizontal, 16).frame(height: 34)
            .background(Capsule().fill(prominent ? IslandColor.green : .white.opacity(0.12)))
            .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
