import SwiftUI
import PDFKit
import SwiftTerm
import UniformTypeIdentifiers

// MARK: - Terminal

/// SwiftTerm view that boots `claude` once it has real geometry, so the PTY
/// spawns at the correct width (same trick as ClaudeDeck).
final class ClaudeTerminalView: LocalProcessTerminalView {
    private var started = false
    private var startedAt = Date()
    // The view can't be its own processDelegate (it already defines the
    // protocol's methods as non-open), so a tiny relay object forwards exits.
    private lazy var relay = ProcessExitRelay(owner: self)

    override func layout() {
        super.layout()
        guard !started, bounds.width > 1, bounds.height > 1 else { return }
        started = true
        processDelegate = relay
        start()
    }

    private func start() {
        startedAt = Date()
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        startProcess(executable: "/bin/zsh",
                     args: ["-l", "-i", "-c", "exec claude"],
                     environment: env.map { "\($0.key)=\($0.value)" },
                     execName: nil,
                     currentDirectory: NSHomeDirectory())
    }

    fileprivate func handleExit(code: Int32?) {
        // A session that ran a while and ended (e.g. /exit, crash of the CLI)
        // gets relaunched so the pane never sits dead. An immediate exit means
        // claude can't start — don't loop, say so.
        if Date().timeIntervalSince(startedAt) > 5 {
            feed(text: "\r\n[claude exited (code \(code ?? -1)) — restarting]\r\n")
            start()
        } else {
            feed(text: "\r\n[claude failed to start — is `claude` on PATH for zsh?]\r\n")
        }
    }
}

private final class ProcessExitRelay: LocalProcessTerminalViewDelegate {
    weak var owner: ClaudeTerminalView?
    init(owner: ClaudeTerminalView) { self.owner = owner }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.owner?.handleExit(code: exitCode)
        }
    }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

struct TerminalHost: NSViewRepresentable {
    let view: ClaudeTerminalView
    func makeNSView(context: Context) -> ClaudeTerminalView { view }
    func updateNSView(_ nsView: ClaudeTerminalView, context: Context) {}
}

// MARK: - Variances

/// One numbered difference between the two contracts, as reported by claude.
struct Variance: Codable, Identifiable {
    let n: Int
    let a: String   // short verbatim quote from doc A ("" if clause absent)
    let b: String   // short verbatim quote from doc B
    let note: String?
    var approved: Bool?   // optional so claude's JSON (no such key) decodes
    var id: Int { n }
    var isApproved: Bool { approved ?? false }
}

/// A user-added annotation: a quote in one pane plus a note.
struct UserNote: Codable, Identifiable {
    let id: UUID
    let pane: Int
    let quote: String
    let note: String
}

/// A saved comparison: which docs, claude's variances (with approvals), user notes.
struct Comparison: Codable {
    var name: String
    var date: Date
    var paths: [String?]
    var variances: [Variance]
    var notes: [UserNote]
}

// MARK: - State

@MainActor @Observable
final class AppState {
    var urls: [URL?] = [nil, nil]
    var showWalkthrough = !UserDefaults.standard.bool(forKey: "walkthroughSeen")
    var variances: [Variance] = []
    var notes: [UserNote] = []
    var soloPane: Int? = nil
    var showInspector = false

    @ObservationIgnored let pdfViews: [PDFView] = (0..<2).map { _ in
        let v = PDFView()
        v.autoScales = true
        return v
    }
    @ObservationIgnored var lastPane = 0
    @ObservationIgnored let terminal = ClaudeTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 300))

    /// Where claude drops the numbered-variance JSON; polled every 2s.
    @ObservationIgnored let markupURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".contract-deck/variances.json")
    @ObservationIgnored private var markupMtime: Date?
    /// Per-variance located selections [paneA, paneB] for the jump menu.
    @ObservationIgnored private var located: [Int: [PDFSelection?]] = [:]
    @ObservationIgnored private var locatedNotes: [UUID: PDFSelection] = [:]
    @ObservationIgnored let comparisonsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".contract-deck/comparisons")

    init() {
        // ponytail: `open --args left.pdf right.pdf` loads the panes at launch
        let pdfs = CommandLine.arguments.dropFirst().filter { $0.lowercased().hasSuffix(".pdf") }
        for (i, path) in pdfs.prefix(2).enumerated() { load(URL(fileURLWithPath: path), into: i) }
        try? FileManager.default.createDirectory(at: comparisonsDir,
                                                 withIntermediateDirectories: true)
        // A variances.json left over from a previous session must not auto-load
        // at launch — mark its current mtime as already seen; only writes made
        // after launch (a fresh Compare) trigger the poller.
        markupMtime = (try? FileManager.default.attributesOfItem(atPath: markupURL.path)[.modificationDate]) as? Date
        // ponytail: 2s mtime poll instead of a DispatchSource watcher
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMarkup() }
        }
    }

    func load(_ url: URL, into pane: Int) {
        guard let doc = PDFDocument(url: url) else { NSSound.beep(); return }
        urls[pane] = url
        pdfViews[pane].document = doc
        applyMarkup()   // re-stamp existing variances onto the fresh document
    }

    /// Type text into the claude prompt without submitting, then focus the
    /// terminal so the user can finish the question and hit Return.
    private func type(_ text: String) {
        terminal.send(txt: text)
        terminal.window?.makeFirstResponder(terminal)
    }

    func askAboutSelection() {
        let view = pdfViews[lastPane]
        guard let sel = view.currentSelection,
              let raw = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = urls[lastPane] else { NSSound.beep(); return }
        // Newlines would submit the prompt mid-paste; flatten them.
        let text = raw.replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        var page = ""
        if let p = sel.pages.first, let doc = view.document {
            page = " page \(doc.index(for: p) + 1)"
        }
        type("From '\(url.path)'\(page), highlighted: \"\(text)\" — ")
    }

    func compareBoth() {
        guard let a = urls[0], let b = urls[1] else { NSSound.beep(); return }
        // Fresh run: clear stale markup so old badges vanish and the poller
        // fires on the newly written file.
        try? FileManager.default.removeItem(at: markupURL)
        markupMtime = nil
        variances = []
        applyMarkup()
        type("""
        Read '\(a.path)' and '\(b.path)' and compare these two contracts clause by clause. \
        Number every variance V1, V2, … and write \(markupURL.path) as a JSON array \
        [{"n":1,"a":"short quote from first doc","b":"short quote from second doc","note":"what changed"}] \
        where each quote is copied VERBATIM from that PDF's extracted text, at most 12 words, unique \
        enough to find by text search; use "" when the clause is absent from that doc. \
        Then summarize each variance here by its V number, flagging differences in terms, \
        obligations, money, and dates.
        """.replacingOccurrences(of: "\n", with: ""))
    }

    // MARK: Markup

    private func pollMarkup() {
        guard let mtime = try? FileManager.default.attributesOfItem(atPath: markupURL.path)[.modificationDate] as? Date,
              mtime != markupMtime else { return }
        markupMtime = mtime
        guard let data = try? Data(contentsOf: markupURL),
              let parsed = try? JSONDecoder().decode([Variance].self, from: data) else { return }
        variances = parsed
        applyMarkup()
        showInspector = true   // approvals happen here as results show up
    }

    /// Find a quote in a pane's doc and stamp highlight lines + a margin badge.
    /// The badge sits at the page's left edge (x=2), never over the text block.
    /// Returns the located selection, or nil.
    private func stamp(doc: PDFDocument, quote: String, label: String,
                       highlight: NSColor, badgeColor: NSColor) -> PDFSelection? {
        guard !quote.isEmpty,
              let sel = doc.findString(quote, withOptions: [.caseInsensitive, .diacriticInsensitive]).first
        else { return nil }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let hl = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                hl.color = highlight
                hl.userName = "ContractDeck"
                page.addAnnotation(hl)
            }
        }
        if let page = sel.pages.first {
            let b = sel.bounds(for: page)
            // ponytail: two quotes on the same line would overlap badges; fine for contracts
            let badge = PDFAnnotation(bounds: CGRect(x: 2, y: b.maxY - 12, width: 22, height: 12),
                                      forType: .freeText, withProperties: nil)
            badge.contents = label
            badge.font = NSFont.boldSystemFont(ofSize: 8)
            badge.fontColor = .white
            badge.color = badgeColor
            badge.userName = "ContractDeck"
            page.addAnnotation(badge)
        }
        return sel
    }

    /// Re-stamp both panes: variances (yellow, green once approved) + user notes (blue).
    private func applyMarkup() {
        located = [:]
        locatedNotes = [:]
        for pane in 0..<2 {
            guard let doc = pdfViews[pane].document else { continue }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                for ann in page.annotations where ann.userName == "ContractDeck" {
                    page.removeAnnotation(ann)
                }
            }
            for v in variances {
                let hl: NSColor = v.isApproved ? NSColor.systemGreen.withAlphaComponent(0.35)
                                               : NSColor.systemYellow.withAlphaComponent(0.5)
                let sel = stamp(doc: doc, quote: pane == 0 ? v.a : v.b, label: "V\(v.n)",
                                highlight: hl, badgeColor: v.isApproved ? .systemGreen : .systemRed)
                located[v.n, default: [nil, nil]][pane] = sel
            }
            for (i, note) in notes.enumerated() where note.pane == pane {
                if let sel = stamp(doc: doc, quote: note.quote, label: "N\(i + 1)",
                                   highlight: NSColor.systemBlue.withAlphaComponent(0.3),
                                   badgeColor: .systemBlue) {
                    locatedNotes[note.id] = sel
                }
            }
        }
    }

    /// Scroll both panes to variance n.
    func goTo(_ n: Int) {
        guard let sels = located[n] else { return }
        for pane in 0..<2 {
            if let sel = sels[pane] { pdfViews[pane].go(to: sel) }
        }
    }

    func goToNote(_ note: UserNote) {
        if let sel = locatedNotes[note.id] { pdfViews[note.pane].go(to: sel) }
    }

    func toggleApproved(_ n: Int) {
        guard let i = variances.firstIndex(where: { $0.n == n }) else { return }
        variances[i].approved = !variances[i].isApproved
        applyMarkup()
    }

    /// Turn the current selection into a user note (blue markup) on its pane.
    func annotateSelection() {
        let pane = soloPane ?? lastPane
        guard let sel = pdfViews[pane].currentSelection,
              let raw = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { NSSound.beep(); return }
        guard let text = Self.prompt("Note for this passage:", initial: "") else { return }
        let quote = raw.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
        notes.append(UserNote(id: UUID(), pane: pane, quote: quote, note: text))
        applyMarkup()
    }

    func deleteNote(_ note: UserNote) {
        notes.removeAll { $0.id == note.id }
        applyMarkup()
    }

    // MARK: Saved comparisons

    var savedComparisons: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: comparisonsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func saveComparison() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm"
        guard let name = Self.prompt("Name this comparison:", initial: df.string(from: Date())),
              !name.isEmpty else { return }
        let comp = Comparison(name: name, date: Date(), paths: urls.map { $0?.path },
                              variances: variances, notes: notes)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        if let data = try? JSONEncoder().encode(comp) {
            try? data.write(to: comparisonsDir.appendingPathComponent(safe + ".json"))
        }
    }

    func loadComparison(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let comp = try? JSONDecoder().decode(Comparison.self, from: data) else { NSSound.beep(); return }
        variances = comp.variances
        notes = comp.notes
        for (i, path) in comp.paths.enumerated() where path != nil {
            load(URL(fileURLWithPath: path!), into: i)   // load() re-applies markup
        }
        applyMarkup()   // covers the no-docs-changed case
        showInspector = true
    }

    private static func prompt(_ title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

// MARK: - PDF pane

struct PDFPane: View {
    @Bindable var state: AppState
    let pane: Int
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(state.urls[pane]?.lastPathComponent ?? "No document")
                    .lineLimit(1).font(.callout)
                Spacer()
                Button(state.soloPane == pane ? "Both" : "Solo") {
                    state.soloPane = state.soloPane == pane ? nil : pane
                }.controlSize(.small)
                Button("Open…") { importing = true }.controlSize(.small)
            }
            .padding(6)
            PDFViewRepresentable(view: state.pdfViews[pane])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) {
            if case .success(let url) = $0 { state.load(url, into: pane) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension.lowercased() == "pdf" else { return false }
            state.load(url, into: pane)
            return true
        }
    }
}

struct PDFViewRepresentable: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

// MARK: - Markup list (inspector)

struct MarkupList: View {
    @Bindable var state: AppState

    var body: some View {
        List {
            Section("Variances") {
                ForEach(state.variances) { v in
                    HStack(alignment: .firstTextBaseline) {
                        Text("V\(v.n)").bold()
                            .foregroundStyle(v.isApproved ? Color.green : Color.red)
                        Text(v.note ?? "").font(.callout).lineLimit(3)
                        Spacer()
                        Button {
                            state.toggleApproved(v.n)
                        } label: {
                            Image(systemName: v.isApproved ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(v.isApproved ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(v.isApproved ? "Approved — click to un-approve" : "Approve this change")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.goTo(v.n) }
                }
                if state.variances.isEmpty {
                    Text("Run “Compare Both” to get numbered variances.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("My Notes") {
                ForEach(Array(state.notes.enumerated()), id: \.element.id) { i, note in
                    HStack(alignment: .firstTextBaseline) {
                        Text("N\(i + 1)").bold().foregroundStyle(Color.blue)
                        Text(note.note).font(.callout).lineLimit(3)
                        Spacer()
                        Button { state.deleteNote(note) } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.goToNote(note) }
                }
                if state.notes.isEmpty {
                    Text("Highlight a passage and press “Annotate”.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Walkthrough

struct WalkthroughView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Contract Deck").font(.title2.bold())
            Text("""
            1. Open (or drag in) a contract PDF on each side.
            2. Highlight any passage with the mouse.
            3. Press ⌘⏎ (or “Ask About Highlight”) — the passage, file, and page \
            are typed into Claude below. Finish your question and hit Return.
            4. “Compare Both” asks Claude to diff the two contracts. Claude numbers \
            every variance (V1, V2, …); both PDFs get margin V-badges + highlights, \
            and the side panel lists them — click a row to jump, tick ◯ to approve \
            (turns green). “Save Comparison…” in the Versions menu keeps it all; \
            reload any saved version from the same menu.
            5. “Solo” on a pane focuses one doc; highlight + “Annotate” adds your \
            own blue note (N1, N2, …), saved with the comparison.

            The bottom pane is a full live Claude Code terminal — type anything.
            Re-open this from Help → Contract Deck Walkthrough.
            """)
            Button("Got It") {
                UserDefaults.standard.set(true, forKey: "walkthroughSeen")
                state.showWalkthrough = false
            }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Main

struct ContentView: View {
    @Bindable var state: AppState

    var body: some View {
        VSplitView {
            HSplitView {
                if state.soloPane != 1 { PDFPane(state: state, pane: 0).frame(minWidth: 250) }
                if state.soloPane != 0 { PDFPane(state: state, pane: 1).frame(minWidth: 250) }
            }
            .frame(minHeight: 300)
            TerminalHost(view: state.terminal)
                .frame(minHeight: 160)
        }
        .inspector(isPresented: $state.showInspector) {
            MarkupList(state: state)
                .inspectorColumnWidth(min: 220, ideal: 280)
        }
        .toolbar {
            Button("Ask About Highlight") { state.askAboutSelection() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Annotate") { state.annotateSelection() }
            Button("Compare Both") { state.compareBoth() }
            Menu("Versions") {
                Button("Save Comparison…") { state.saveComparison() }
                Divider()
                ForEach(state.savedComparisons, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) { state.loadComparison(url) }
                }
            }
            Button {
                state.showInspector.toggle()
            } label: {
                Label("Variances", systemImage: "sidebar.trailing")
            }
        }
        .sheet(isPresented: $state.showWalkthrough) { WalkthroughView(state: state) }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewSelectionChanged)) { note in
            // Remember which pane the user last highlighted in.
            if let v = note.object as? PDFView, let i = state.pdfViews.firstIndex(of: v),
               v.currentSelection?.string?.isEmpty == false {
                state.lastPane = i
            }
        }
    }
}

@main
struct ContractDeckApp: App {
    @State private var state = AppState()

    init() {
        // A write to a dead PTY raises SIGPIPE, which kills the app silently
        // (no crash report). Standard PTY-app hygiene: ignore it.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(after: .help) {
                Button("Contract Deck Walkthrough") { state.showWalkthrough = true }
            }
        }
    }
}
