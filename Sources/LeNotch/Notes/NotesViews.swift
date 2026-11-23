import AppKit
import SwiftUI

/// Notes are deliberately plain text: a list of titles/previews, then a focused editor. Every edit
/// goes straight to the local store, including when the card loses focus or closes.
struct NotesPage: View {
    let tray: TrayModel
    let director: IslandDirector
    let store: NotesStore
    @FocusState private var titleFocused: Bool
    @State private var bodyFocused = false
    @State private var focusTask: Task<Void, Never>?
    @State private var bodyFocusRequest = 0
    @Environment(\.islandMotion) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundButton(symbol: "chevron.left", style: .gray, size: 28,
                            label: store.selected == nil ? "Back to tools" : "All notes", action: back)
                Text("Notes").font(IslandType.title)
                Spacer()
                if let note = store.selected {
                    RoundButton(symbol: "trash", style: .gray, size: 26, label: "Delete note") { delete(note.id) }
                } else if !store.notes.isEmpty {
                    Text("\(store.notes.count)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(IslandColor.secondary)
                }
                RoundButton(symbol: "square.and.pencil", style: .gray, size: 28, label: "New note", action: newNote)
            }
            if let error = store.storageError {
                Label("Couldn’t save notes locally", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(IslandColor.orange)
                    .lineLimit(1).help(error).accessibilityHint(error)
            }
            Group {
                if let note = store.selected { editor(note).id(note.id) }
                else { noteList }
            }
            if let removal = store.removal {
                HStack(spacing: 8) {
                    Text("Note deleted").font(.system(size: 11)).foregroundStyle(IslandColor.secondary)
                    Spacer()
                    Button("Undo") { animate { store.undo() } }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandColor.cyan)
                }
                .padding(.horizontal, 12).frame(height: 28)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .task(id: removal.id) {
                    do { try await Task.sleep(for: .seconds(6)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    store.dismissUndo()
                }
            }
        }
        .foregroundStyle(.white)
        .onChange(of: titleFocused) { _, _ in updateFocus() }
        .onChange(of: bodyFocused) { _, _ in updateFocus() }
        .onDisappear {
            focusTask?.cancel()
            focusTask = nil
            director.replyFocused = false
            director.onYieldsKey?()
            store.dismissUndo()
        }
    }

    @ViewBuilder private var noteList: some View {
        if store.notes.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: "note.text").font(.system(size: 25, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                Text("A place for your thoughts").font(.system(size: 14, weight: .semibold))
                Text("Write a note. It stays on this Mac.")
                    .font(.system(size: 12)).foregroundStyle(IslandColor.secondary)
                Button("New note", action: newNote)
                    .buttonStyle(PressScaleStyle())
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(height: 28)
                    .background(.white, in: Capsule()).padding(.top, 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(store.orderedNotes) { note in
                        Button { animate { store.select(note.id) } } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(note.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(note.updatedAt, format: .dateTime.month(.abbreviated).day())
                                        .font(.system(size: 10)).foregroundStyle(IslandColor.secondary)
                                }
                                Text(note.preview).font(.system(size: 12))
                                    .foregroundStyle(IslandColor.secondary).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
                            .contentShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(PressScaleStyle(pressed: 0.99, hover: 1))
                        .accessibilityLabel(note.displayTitle)
                        .accessibilityHint("Open note")
                        .contextMenu {
                            Button("Delete note", role: .destructive) { delete(note.id) }
                        }
                        .accessibilityAction(named: "Delete note") { delete(note.id) }
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func editor(_ note: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if motion.stills {
                    Text(note.displayTitle).font(.system(size: 19, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Title", text: Binding(get: { store.selected?.title ?? "" },
                                                     set: { store.updateTitle(note.id, to: $0) }))
                        .textFieldStyle(.plain).font(.system(size: 19, weight: .semibold))
                        .focused($titleFocused).accessibilityLabel("Note title")
                        .onTapGesture { director.onWantsKey?() }
                        .onSubmit {
                            titleFocused = false
                            director.onWantsKey?()
                            bodyFocusRequest &+= 1
                        }
                        .onExitCommand(perform: releaseKeyboard)
                }
            }
            .lineLimit(1)
            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
            ZStack(alignment: .topLeading) {
                if note.body.isEmpty {
                    Text("Start writing…").font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 6).padding(.leading, 2).allowsHitTesting(false)
                }
                if motion.stills {
                    ScrollView {
                        Text(note.body).font(.system(size: 13)).lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    NotesBodyEditor(text: note.body, focusRequest: bodyFocusRequest,
                                    onChange: { store.updateBody(note.id, to: $0) },
                                    requestKeyboard: { director.onWantsKey?() },
                                    focusChanged: { bodyFocused = $0 }, escape: releaseKeyboard)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text("\(note.body.split(whereSeparator: \.isWhitespace).count) words")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func newNote() {
        releaseKeyboard()
        let id = store.addNote()
        director.analytics.trackFeature(.notes, action: "add_note")
        director.onWantsKey?()
        focusTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(60)) }
            catch { return }
            guard !Task.isCancelled, store.selectedID == id else { return }
            titleFocused = true
            focusTask = nil
        }
    }

    private func back() {
        releaseKeyboard()
        if store.selected == nil { tray.go(.main) }
        else { animate { store.select(nil) } }
    }

    private func delete(_ id: UUID) {
        releaseKeyboard()
        animate { store.delete(id) }
    }

    private func releaseKeyboard() {
        focusTask?.cancel()
        focusTask = nil
        titleFocused = false
        bodyFocused = false
        director.replyFocused = false
        director.onYieldsKey?()
    }

    private func updateFocus() { director.replyFocused = titleFocused || bodyFocused }
    private func animate(_ action: () -> Void) {
        withAnimation(motion.reduce || motion.stills ? nil : .easeOut(duration: 0.18), action)
    }
}

/// A real multiline AppKit editor: native selection, scrolling, text shortcuts and undo. Model
/// updates never replace unchanged text, preserving the caret while each keystroke is saved.
struct NotesBodyEditor: NSViewRepresentable {
    let text: String
    var focusRequest: Int = 0
    let onChange: (String) -> Void
    let requestKeyboard: () -> Void
    let focusChanged: (Bool) -> Void
    let escape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let editor = NotesTextView(frame: .zero)
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.font = .systemFont(ofSize: 13)
        editor.textContainerInset = NSSize(width: 2, height: 6)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        editor.defaultParagraphStyle = paragraph
        editor.string = text
        editor.setAccessibilityLabel("Note text")
        context.coordinator.configure(editor)
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NotesTextView else { return }
        context.coordinator.configure(editor)
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if focusRequest != context.coordinator.appliedFocusRequest {
            context.coordinator.appliedFocusRequest = focusRequest
            if focusRequest > 0 {
                // Focus callbacks change SwiftUI state, so let this view update finish first.
                DispatchQueue.main.async { [weak editor] in
                    guard let editor, let window = editor.window else { return }
                    window.makeFirstResponder(editor)
                }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesBodyEditor
        var appliedFocusRequest = 0
        init(_ parent: NotesBodyEditor) { self.parent = parent }
        func configure(_ editor: NotesTextView) {
            editor.requestKeyboard = parent.requestKeyboard
            editor.focusChanged = parent.focusChanged
            editor.escape = parent.escape
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.onChange(editor.string)
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let replacementString, let range = Range(affectedCharRange, in: textView.string) else { return true }
            let remaining = textView.string.count - textView.string[range].count
            return remaining + replacementString.count <= NotesStore.bodyLimit
        }
    }
}

final class NotesTextView: NSTextView {
    var requestKeyboard: (() -> Void)?
    var focusChanged: ((Bool) -> Void)?
    var escape: (() -> Void)?
    override func mouseDown(with event: NSEvent) { requestKeyboard?(); super.mouseDown(with: event) }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            escape?()
        } else { super.keyDown(with: event) }
    }
}
