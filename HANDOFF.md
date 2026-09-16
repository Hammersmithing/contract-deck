# Contract Deck — Design Handoff

Handoff for a design-focused Claude session. Goal: improve the look, feel, and
UX of the app **without breaking its working machinery**. Read this, then
`CLAUDE.md`, then `ContractDeck/App.swift` (single source file, ~450 lines).

## What this app is

macOS app (SwiftUI + AppKit, macOS 14+) for reviewing contract PDFs with
Claude. One window:

- Two side-by-side **PDF panes** (PDFKit) — contract version A and B.
- A live **Claude Code terminal** underneath (SwiftTerm PTY running `claude`).
- A trailing **inspector panel** listing variances and user notes.

Owner: James (Hammersmithing). Real use case: reviewing client contract
redlines — comparing the version that came back against the one sent out.

## Working feature set (v as of 2026-09-16, commit `01bbcb1`)

1. **Ask About Highlight (⌘⏎)** — selection in a PDF is typed into the claude
   prompt as `From '<path>' page N, highlighted: "…" — `; user finishes the
   question, hits Return. Never auto-submits.
2. **Compare Both** — prompts claude to diff both PDFs, number variances
   V1, V2, …, and write `~/.contract-deck/variances.json` (short verbatim
   quotes per doc + note). App polls mtime every 2s; on arrival, quotes are
   located via `PDFDocument.findString` and stamped as annotations.
3. **Markup**: unresolved variance = yellow highlight + orange margin badge.
   Badges are at the page's left edge (x=2) — deliberately, they used to cover
   text.
4. **Keep doc + approval**: star (★) in a pane header marks the doc being
   kept. Approving a variance (circle in inspector) = keep-doc wording wins:
   winner green highlight, loser red + strikeout. A/B buttons per row override
   the winner per clause; same winner again reopens.
5. **User notes**: "Annotate" turns the current highlight into a blue
   N-numbered note with text; listed in inspector, deletable.
6. **Saved comparisons ("versions")**: Versions menu → Save Comparison…
   writes name/date/doc paths/variances(+resolutions)/notes/keepPane to
   `~/.contract-deck/comparisons/<name>.json`; menu lists saved files, click
   reloads everything.
7. **Solo** — per-pane button collapses to one doc full-width.
8. **First-run walkthrough** sheet, re-showable from Help menu (house rule:
   every GUI app must have this — do not remove, keep it updated).
9. Terminal hardening: SIGPIPE ignored; claude auto-restarts if it exits
   after >5s (message + PATH hint on instant failure).

## Architecture map (all in `ContractDeck/App.swift`)

- `ClaudeTerminalView` + `ProcessExitRelay` — SwiftTerm subclass; spawns
  `zsh -l -i -c "exec claude"` on first real layout; restart-on-exit.
- `Variance`, `UserNote`, `Comparison` — Codable model. `Variance.keep:
  Int?` (0=A wins, 1=B wins, nil=open) is optional **so claude's JSON
  decodes**; `Comparison.keepPane` optional for old saves.
- `AppState` (@Observable, MainActor) — owns two `PDFView`s and the terminal
  view for the app's lifetime; SwiftUI representables only mount them.
  Markup engine: `stamp()` (findString → per-line highlight (+strikeout) +
  margin freeText badge), `applyMarkup()` (clears annotations with
  `userName == "ContractDeck"`, re-stamps variances + notes), 2s
  `pollMarkup()` timer (mtime-seeded at init so stale files don't load).
- Views: `PDFPane` (header: ★ keep, filename, KEEPING tag, Solo, Open…),
  `MarkupList` (inspector), `WalkthroughView`, `ContentView` (VSplit/HSplit +
  toolbar), `ContractDeckApp`.

## Build / verify

- `./build.sh` — xcodegen + Release build + install to /Applications +
  launch. Only supported build path.
- No tests; drives the real `claude` CLI. Verify by exercising flows.
  Test assets: two generated contracts + a variances.json injection flow —
  see repo history commit messages, or regenerate: any two PDFs + hand-write
  `~/.contract-deck/variances.json` (poller picks it up within 2s while docs
  are loaded).
- SourceKit shows "No such module 'SwiftTerm'" in editors — noise;
  xcodebuild resolves the package fine.

## Known design problems (the actual job)

- **No app icon.** No asset catalog at all.
- Toolbar is a flat row of text buttons (Ask About Highlight / Annotate /
  Compare Both / Versions / inspector toggle) — no icons, no grouping, no
  hierarchy.
- Pane headers are cramped: star, filename, KEEPING tag, Solo, Open… in one
  small HStack.
- Inspector rows are dense: V-number, note text, A/B bordered buttons, and a
  circle in one row; section header carries instruction text as a title —
  ugly. Empty states are plain gray sentences.
- Badge/highlight visual language (yellow/green/red, orange/green/red badges,
  blue notes) works but was never designed; badges are 8pt bold white text on
  flat color at the page edge, can collide when two variances share a line.
- Walkthrough is a wall of numbered text in a fixed 480pt sheet.
- Terminal is stock SwiftTerm — no theming (compare: ClaudeDeck's Tron
  remap at `~/projects/claudedeck/` for what a themed SwiftTerm looks like).
- No visual link between an inspector row and its in-doc badge beyond the
  number; no hover/selection affordance in the PDFs.
- Window has no title beyond default; panes don't indicate A/B identity
  anywhere except implicit position (inspector says "A/B", panes don't).

## Constraints — do not break

- **Machinery is verified and load-bearing**: quote-location via verbatim
  `findString` (known ceiling: curly-quote/ligature mismatch → variance
  silently unlocated), the 2s poller, annotation clearing by
  `userName == "ContractDeck"`, terminal restart logic, saved-comparison
  JSON shape (old files must keep decoding — only add optional fields).
- PDFView and terminal instances must stay owned by `AppState` (recreating
  them kills the PTY / document state).
- Sandbox stays OFF. Deployment target macOS 14.
- House rules: KISS ladder (fewest lines, no speculative abstraction);
  walkthrough tutorial must exist and stay current; never `git push` —
  James pushes; never hard-delete anything (trash only; note `rm` in his
  shell is trash-backed, `/bin/rm` is real).
- Keep it one source file unless growth genuinely forces a split.

## Repo

`~/projects/contract-deck/`, GitHub `Hammersmithing/contract-deck` (private,
pushed through `01bbcb1`). Work on a short-lived feature branch off `main`,
small verified commits, merge locally; James reviews and pushes.
