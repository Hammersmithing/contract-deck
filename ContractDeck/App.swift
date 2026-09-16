import SwiftUI
import PDFKit
import SwiftTerm
import UniformTypeIdentifiers

// MARK: - Terminal

/// SwiftTerm view that boots `claude` once it has real geometry, so the PTY
/// spawns at the correct width (same trick as ClaudeDeck).
final class ClaudeTerminalView: LocalProcessTerminalView {
    private var started = false

    override func layout() {
        super.layout()
        guard !started, bounds.width > 1, bounds.height > 1 else { return }
        started = true
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
}

struct TerminalHost: NSViewRepresentable {
    let view: ClaudeTerminalView
    func makeNSView(context: Context) -> ClaudeTerminalView { view }
    func updateNSView(_ nsView: ClaudeTerminalView, context: Context) {}
}

// MARK: - State

@MainActor @Observable
final class AppState {
    var urls: [URL?] = [nil, nil]
    var showWalkthrough = !UserDefaults.standard.bool(forKey: "walkthroughSeen")

    @ObservationIgnored let pdfViews: [PDFView] = (0..<2).map { _ in
        let v = PDFView()
        v.autoScales = true
        return v
    }
    @ObservationIgnored var lastPane = 0
    @ObservationIgnored let terminal = ClaudeTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 300))

    func load(_ url: URL, into pane: Int) {
        guard let doc = PDFDocument(url: url) else { NSSound.beep(); return }
        urls[pane] = url
        pdfViews[pane].document = doc
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
        type("Read '\(a.path)' and '\(b.path)' and compare these two contracts clause by clause. Flag every difference in terms, obligations, money, and dates. ")
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
            4. “Compare Both” asks Claude to diff the two contracts clause by clause.

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
