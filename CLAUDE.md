# Contract Deck — agent context

SwiftUI macOS app: two PDFKit panes + embedded live `claude` session
(SwiftTerm PTY). Highlight in a PDF → passage/file/page typed into the claude
prompt for the user to finish.

## Build / run
- `./build.sh` — xcodegen, Release build, install to /Applications, launch.
- Sandbox intentionally OFF (spawns /bin/zsh + claude, reads PDFs anywhere).

## Architecture
- Single source file `ContractDeck/App.swift`. `AppState` owns two PDFView
  instances and one `ClaudeTerminalView` for the app's lifetime; SwiftUI
  representables only mount them.
- `ClaudeTerminalView` delays `startProcess` until first non-zero layout so
  the PTY spawns at real width (pattern from ClaudeDeck).
- Text sent to the terminal never includes newlines (they'd submit the
  prompt); selections are flattened to one line.

## Verifying changes
- No tests; drives the real `claude` CLI. Run `./build.sh` and exercise:
  open two PDFs, highlight, ⌘⏎, Compare Both, walkthrough from Help menu.
