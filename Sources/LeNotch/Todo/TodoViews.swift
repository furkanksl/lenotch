import SwiftUI

/// The To-do tool's page: the lists as chips along the top, the chosen list's to-dos below, and the field to add one
/// pinned at the bottom. Open to-dos come first in the order they were added; finished ones sink under a "Done" line
/// and can be cleared together.
///
/// Typing needs the keyboard, which the notch's panel only takes when asked. A field in use holds the card open the way
/// the Messages reply does, and Esc lets go.
struct TodoPage: View {
    let tray: TrayModel
    let director: IslandDirector
    let store: TodoStore

    /// Each place text can be typed. The composer is always there; the others open in place of a name or a title.
    enum Field: Hashable { case composer, newList, list(UUID), item(UUID) }

    @State private var draft = ""
    @State private var editing: Field?
    @State private var editText = ""
    @State private var focusTask: Task<Void, Never>?
    @FocusState private var focus: Field?
    @Environment(\.islandMotion) private var motion

    /// Where the new list's name field sits in the chips, to bring it into view.
    static let newListID = "new-list"
    static let rowHeight = 32.0
    static let chipHeight = 28.0
    static let composerHeight = 34.0

    var body: some View {
        Page(tray: tray, title: "To-do", status: store.storageError == nil ? nil : "Local storage needs attention") {
            ScrollViewReader { proxy in
                VStack(spacing: 8) {
                    if !store.lists.isEmpty || editing == .newList { chips }
                    items
                    composer(proxy)
                }
                .onChange(of: editing) { _, new in
                    if new == .newList { animate { proxy.scrollTo(Self.newListID, anchor: .trailing) } }
                }
                .onChange(of: store.selected?.id) { _, id in
                    if let id { animate { proxy.scrollTo(id) } }
                }
            }
        }
        .help(store.storageError ?? "Create lists and to-dos, saved on this Mac. Double-click a name to edit it.")
        .onChange(of: focus) { old, new in
            director.replyFocused = new != nil
            // Only the field actually losing focus commits. A newly opened editor must not be
            // committed (and removed) while focus is still moving away from the previous field.
            if let editing, old == editing, new != editing { commitEdit(releaseFocus: false) }
        }
        .onDisappear {
            focusTask?.cancel()
            focusTask = nil
            commitEdit()
            director.replyFocused = false
            director.onYieldsKey?()
            store.dismissUndo()
        }
    }

    // MARK: - Lists

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.lists) { list in
                    if editing == .list(list.id) {
                        chipField(placeholder: "List name", field: .list(list.id))
                    } else {
                        TodoChip(list: list, selected: list.id == store.selected?.id,
                                 select: { animate { store.selectList(list.id) } },
                                 rename: { beginEdit(.list(list.id), text: list.title) },
                                 delete: { animate { store.deleteList(list.id) } })
                    }
                }
                if editing == .newList {
                    chipField(placeholder: "New list", field: .newList).id(Self.newListID)
                } else {
                    Button { beginEdit(.newList, text: "") } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .frame(width: Self.chipHeight, height: Self.chipHeight)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressScaleStyle(pressed: 0.9, hover: 1.05))
                    .help("New list")
                    .accessibilityLabel("New list")
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
        .scrollEdgeFade(.horizontal, length: 24)
        .frame(height: Self.chipHeight + 2)
    }

    private func chipField(placeholder: String, field: Field) -> some View {
        TodoField(text: $editText, placeholder: placeholder, field: field, focus: $focus,
                  font: .system(size: 12, weight: .semibold), onSubmit: commitEdit, onCancel: cancelEdit)
            .padding(.horizontal, 12)
            .frame(width: 130, height: Self.chipHeight)
            .background(Capsule().fill(.white.opacity(0.14)))
            .capsuleBorder(.white.opacity(0.4), width: 1)
    }

    // MARK: - To-dos

    private enum Entry: Identifiable {
        case item(TodoItem)
        case doneHeader(count: Int)

        var id: String {
            switch self {
            case .item(let item): item.id.uuidString
            case .doneHeader: "done-header"
            }
        }
    }

    private func entries(_ list: TodoList) -> [Entry] {
        let done = list.done
        return list.open.map(Entry.item) + (done.isEmpty ? [] : [.doneHeader(count: done.count)] + done.map(Entry.item))
    }

    @ViewBuilder private var items: some View {
        ZStack(alignment: .bottom) {
            if let list = store.selected {
                if list.items.isEmpty {
                    TodoEmpty(symbol: "checkmark.circle", title: "Nothing to do", detail: "Add the first one below.")
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 2) {
                            ForEach(entries(list)) { entry in
                                switch entry {
                                case .item(let item):
                                    TodoRow(item: item, editing: editing == .item(item.id), text: $editText, focus: $focus,
                                            toggle: { animate { store.toggle(item.id) } },
                                            beginEdit: { beginEdit(.item(item.id), text: item.title) },
                                            commit: commitEdit, cancel: cancelEdit,
                                            delete: { animate { store.deleteItem(item.id) } })
                                        .transition(.opacity)
                                case .doneHeader(let count):
                                    TodoDoneHeader(count: count) { animate { store.clearCompleted(in: list.id) } }
                                        .transition(.opacity)
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .scrollIndicators(.never)
                    .scrollEdgeFade(.vertical, length: 14)
                    .id("todo-items-\(list.id)")   // reset only the task scroll view, not the chip's scroll identity
                }
            } else {
                TodoEmpty(symbol: "checklist", title: "No lists yet", detail: "Make one to start.",
                          action: ("New list", { beginEdit(.newList, text: "") }))
            }
            if let removal = store.removal {
                TodoUndoPill(text: Self.describe(removal)) { animate { store.undo() } }
                    .padding(.bottom, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: removal.id) {
                        try? await Task.sleep(for: .seconds(6))
                        if !Task.isCancelled { animate { store.dismissUndo() } }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func describe(_ removal: TodoStore.Removal) -> String {
        switch removal.kind {
        case .item(let item, _, _): "Deleted “\(item.title)”"
        case .completed(let items, _): items.count == 1 ? "Cleared 1 done" : "Cleared \(items.count) done"
        case .list(let list, _): "Deleted “\(list.title)”"
        }
    }

    // MARK: - Composer

    private func composer(_ proxy: ScrollViewProxy) -> some View {
        let enabled = store.selected != nil
        let ready = enabled && !draft.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5)).frame(width: 14)
            TodoField(text: $draft, placeholder: enabled ? "Add to \(store.selected?.title ?? "")" : "Make a list first",
                      field: .composer, focus: $focus, font: .system(size: 13),
                      onSubmit: { add(proxy) }, onCancel: { focus = nil; director.onYieldsKey?() })
                .disabled(!enabled)
                .onChange(of: draft) { _, text in
                    if text.count > TodoStore.titleLimit { draft = String(text.prefix(TodoStore.titleLimit)) }
                }
            if ready {
                Button { add(proxy) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 24, height: 24).background(Circle().fill(.white)).contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle(pressed: 0.85, hover: 1.06))
                .accessibilityLabel("Add to-do")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 12).padding(.trailing, ready ? 5 : 12)
        .frame(height: Self.composerHeight)
        .background(Capsule().fill(.white.opacity(0.1)))
        .capsuleBorder(.white.opacity(focus == .composer ? 0.35 : 0.12), width: focus == .composer ? 1 : 0.5)
        .contentShape(Capsule())
        .onTapGesture { if enabled { takeKeyboard(.composer) } }
        .animation(motion.reduce || motion.stills ? nil : .easeOut(duration: 0.15), value: ready)
    }

    private func add(_ proxy: ScrollViewProxy) {
        guard let id = store.addItem(draft) else { return }
        draft = ""
        // Entry IDs are strings (the completed-section header uses the same ForEach). Use the
        // matching ID, after SwiftUI has inserted the new row, not the task's raw UUID.
        Task { @MainActor in
            await Task.yield()
            animate { proxy.scrollTo(id.uuidString, anchor: .center) }
        }
    }

    // MARK: - Editing in place

    private func beginEdit(_ field: Field, text: String) {
        commitEdit(releaseFocus: false)
        editText = text
        editing = field
        takeKeyboard(field)
    }

    /// Asks for the keyboard, then focuses once the field is on screen.
    private func takeKeyboard(_ field: Field) {
        focusTask?.cancel()
        director.onWantsKey?()
        focusTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            focus = field
            focusTask = nil
        }
    }

    private func commitEdit() {
        commitEdit(releaseFocus: true)
    }

    private func commitEdit(releaseFocus: Bool) {
        guard let field = editing else { return }
        let text = editText
        editing = nil
        switch field {
        case .newList: store.addList(text)
        case .list(let id): store.renameList(id, to: text)
        case .item(let id): store.renameItem(id, to: text)
        case .composer: break
        }
        if releaseFocus, focus == field { focus = nil }
    }

    private func cancelEdit() {
        focusTask?.cancel()
        focusTask = nil
        editing = nil
        focus = nil
        director.onYieldsKey?()
    }

    private func animate(_ change: () -> Void) {
        if motion.reduce || motion.stills { change() } else { withAnimation(.spring(response: 0.32, dampingFraction: 0.86), change) }
    }
}

// MARK: - Pieces

/// A text field that is only a field when the page is live; a still render (snapshots) draws its text instead.
private struct TodoField: View {
    @Binding var text: String
    let placeholder: String
    let field: TodoPage.Field
    let focus: FocusState<TodoPage.Field?>.Binding
    var font: Font
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @Environment(\.islandMotion) private var motion

    var body: some View {
        if motion.stills {
            Text(text.isEmpty ? placeholder : text).font(font)
                .foregroundStyle(.white.opacity(text.isEmpty ? 0.4 : 1)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(font)
                .focused(focus, equals: field)
                .onSubmit(onSubmit)
                .onExitCommand(perform: onCancel)
                .accessibilityLabel(placeholder)
        }
    }
}

/// A list's chip: its name and what is left in it. The chosen one is lit, and shows a delete mark in the count's place
/// while the pointer is over it. Double-click renames.
private struct TodoChip: View {
    let list: TodoList
    let selected: Bool
    let select: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        let showsDelete = selected && hovering
        ZStack(alignment: .trailing) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Text(list.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: 130)
                    Text(list.openCount == 0 ? " " : "\(list.openCount)")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(selected ? Color.black.opacity(0.5) : .white.opacity(0.5))
                        .opacity(showsDelete ? 0 : 1)
                        .frame(minWidth: 10)
                }
                .foregroundStyle(selected ? Color.black : .white.opacity(0.85))
                .padding(.horizontal, 12).frame(height: TodoPage.chipHeight)
                .background(Capsule().fill(selected ? Color.white : .white.opacity(0.1)))
                .contentShape(Capsule())
            }
            .buttonStyle(PressScaleStyle(pressed: 0.95, hover: 1))
            .simultaneousGesture(TapGesture(count: 2).onEnded { rename() })
            if showsDelete {
                Button(action: delete) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black.opacity(0.65))
                        .frame(width: 16, height: 16).background(Circle().fill(.black.opacity(0.1))).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help("Delete list")
                .accessibilityLabel("Delete \(list.title)")
            }
        }
        .onHover { hovering = $0 }
        .help(selected ? "Double-click to rename" : list.title)
        .contextMenu {
            Button("Rename", action: rename)
            Button("Delete list", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Rename", rename)
        .accessibilityAction(named: "Delete list", delete)
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let editing: Bool
    @Binding var text: String
    let focus: FocusState<TodoPage.Field?>.Binding
    let toggle: () -> Void
    let beginEdit: () -> Void
    let commit: () -> Void
    let cancel: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                TodoCheck(done: item.isDone)
                    .frame(width: 28, height: TodoPage.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark “\(item.title)” as not done" : "Mark “\(item.title)” as done")
            if editing {
                TodoField(text: $text, placeholder: "To-do", field: .item(item.id), focus: focus,
                          font: .system(size: 13), onSubmit: commit, onCancel: cancel)
            } else {
                Text(item.title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    .strikethrough(item.isDone, color: .white.opacity(0.35))
                    .foregroundStyle(item.isDone ? .white.opacity(0.4) : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: TodoPage.rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginEdit)
                    .help(item.title)
            }
            if hovering && !editing {
                Button(action: delete) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.14))).contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle(pressed: 0.85, hover: 1.1))
                .help("Delete")
                .accessibilityLabel("Delete “\(item.title)”")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: TodoPage.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovering || editing ? 0.07 : 0)))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename", action: beginEdit)
            Button(item.isDone ? "Mark as not done" : "Mark as done", action: toggle)
            Button("Delete to-do", role: .destructive, action: delete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit", beginEdit)
        .accessibilityAction(named: "Delete", delete)
    }
}

/// The ring a to-do is ticked in: empty until done, then green with a check.
struct TodoCheck: View {
    let done: Bool
    @Environment(\.islandMotion) private var motion

    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(done ? 0 : 0.42), lineWidth: 1.5)
            Circle().fill(IslandColor.green).opacity(done ? 1 : 0)
            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .heavy)).foregroundStyle(.black)
                .scaleEffect(done ? 1 : 0.4).opacity(done ? 1 : 0)
        }
        .frame(width: 20, height: 20)
        .animation(motion.reduce || motion.stills ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: done)
    }
}

private struct TodoDoneHeader: View {
    let count: Int
    let clear: () -> Void

    var body: some View {
        HStack {
            Text("Done · \(count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Button("Clear", action: clear).buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .accessibilityLabel("Clear \(count) done")
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .padding(.top, 4)
    }
}

private struct TodoEmpty: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular)).foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            if let action {
                Button(action.label, action: action.run).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).frame(height: 26).background(Capsule().fill(.white))
                    .padding(.top, 4)
            }
        }
        .padding(.bottom, 28)   // the undo pill's room, so the two never touch
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TodoUndoPill: View {
    let text: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Button("Undo", action: undo).buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(IslandColor.cyan)
        }
        .padding(.horizontal, 14).frame(height: 30)
        .background(Capsule().fill(Color(white: 0.2)))
        .capsuleBorder(.white.opacity(0.14), width: 0.5)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Helpers

extension View {
    /// A hairline round border drawn inside the shape's edge, so it never spills past it.
    fileprivate func capsuleBorder(_ color: Color, width: Double) -> some View {
        overlay(Capsule().inset(by: width / 2).stroke(color, lineWidth: width))
    }

    /// Fades the end of a scroll view that has more behind it, so a cut-off row reads as "scroll" and not as "the end".
    /// Nothing fades where there is nothing more, and the bars themselves stay hidden on the dark card.
    fileprivate func scrollEdgeFade(_ axis: Axis, length: Double) -> some View {
        modifier(ScrollEdgeFade(axis: axis, length: length))
    }
}

private struct ScrollEdgeFade: ViewModifier {
    struct More: Equatable { var before = false, after = false }

    let axis: Axis
    let length: Double
    @State private var more = More()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: More.self) { geometry in
                let offset = axis == .vertical ? geometry.contentOffset.y : geometry.contentOffset.x
                let extent = axis == .vertical ? geometry.contentSize.height : geometry.contentSize.width
                let visible = axis == .vertical ? geometry.containerSize.height : geometry.containerSize.width
                return More(before: offset > 1, after: offset + visible < extent - 1)
            } action: { _, new in more = new }
            .mask { fade }
    }

    private var fade: some View {
        let solid = Color.black, clear = Color.clear
        let start = LinearGradient(colors: [more.before ? clear : solid, solid],
                                   startPoint: axis == .vertical ? .top : .leading,
                                   endPoint: axis == .vertical ? .bottom : .trailing)
        let end = LinearGradient(colors: [solid, more.after ? clear : solid],
                                 startPoint: axis == .vertical ? .top : .leading,
                                 endPoint: axis == .vertical ? .bottom : .trailing)
        return Group {
            if axis == .vertical {
                VStack(spacing: 0) { start.frame(height: length); solid; end.frame(height: length) }
            } else {
                HStack(spacing: 0) { start.frame(width: length); solid; end.frame(width: length) }
            }
        }
    }
}
