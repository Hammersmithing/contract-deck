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
struct Variance: Decodable, Identifiable {
    let n: Int
    let a: String   // short verbatim quote from doc A ("" if clause absent)
    let b: String   // short verbatim quote from doc B
    let note: String?
    var id: Int { n }
}

// MARK: - State

@MainActor @Observable
final class AppState {
    var urls: [URL?] = [nil, nil]
    var showWalkthrough = !UserDefaults.standard.bool(forKey: "walkthroughSeen")
    var variances: [Variance] = []

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

    init() {
        // ponytail: `open --args left.pdf right.pdf` loads the panes at launch
        let pdfs = CommandLine.arguments.dropFirst().filter { $0.lowercased().hasSuffix(".pdf") }
        for (i, path) in pdfs.prefix(2).enumerated() { load(URL(fileURLWithPath: path), into: i) }
        try? FileManager.default.createDirectory(at: markupURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
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
    }

    /// Stamp both panes: yellow highlight per line + red "V n" badge at the
    /// first line of each located quote.
    private func applyMarkup() {
        located = [:]
        for pane in 0..<2 {
            guard let doc = pdfViews[pane].document else { continue }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                for ann in page.annotations where ann.userName == "ContractDeck" {
                    page.removeAnnotation(ann)
                }
            }
            for v in variances {
                let quote = pane == 0 ? v.a : v.b
                guard !quote.isEmpty,
                      let sel = doc.findString(quote, withOptions: [.caseInsensitive, .diacriticInsensitive]).first
                else { located[v.n, default: [nil, nil]][pane] = nil; continue }
                located[v.n, default: [nil, nil]][pane] = sel
                for line in sel.selectionsByLine() {
                    for page in line.pages {
                        let hl = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                        hl.color = NSColor.systemYellow.withAlphaComponent(0.5)
                        hl.userName = "ContractDeck"
                        page.addAnnotation(hl)
                    }
                }
                if let page = sel.pages.first {
                    let b = sel.bounds(for: page)
                    let badge = PDFAnnotation(bounds: CGRect(x: max(2, b.minX - 30), y: b.maxY - 14, width: 26, height: 14),
                                              forType: .freeText, withProperties: nil)
                    badge.contents = "V\(v.n)"
                    badge.font = NSFont.boldSystemFont(ofSize: 9)
                    badge.fontColor = .white
                    badge.color = .systemRed
                    badge.userName = "ContractDeck"
                    page.addAnnotation(badge)
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
            4. “Compare Both” asks Claude to diff the two contracts clause by clause. \
            Claude numbers every variance (V1, V2, …) and both PDFs get marked up: \
            yellow highlight + red V-badge at each difference. The “Variances” \
            toolbar menu jumps both panes to any V number.

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
                PDFPane(state: state, pane: 0).frame(minWidth: 250)
                PDFPane(state: state, pane: 1).frame(minWidth: 250)
            }
            .frame(minHeight: 300)
            TerminalHost(view: state.terminal)
                .frame(minHeight: 160)
        }
        .toolbar {
            Button("Ask About Highlight") { state.askAboutSelection() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Compare Both") { state.compareBoth() }
            if !state.variances.isEmpty {
                Menu("Variances (\(state.variances.count))") {
                    ForEach(state.variances) { v in
                        Button("V\(v.n)  \(v.note ?? "")") { state.goTo(v.n) }
                    }
                }
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
