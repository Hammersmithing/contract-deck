# Contract Deck

macOS app for comparing contract PDFs with Claude. One window: two PDF panes
side by side, live Claude Code terminal underneath.

## Use
1. Open (or drag in) a contract PDF on each side.
2. Highlight a passage → ⌘⏎ ("Ask About Highlight") types the passage, file
   path, and page number into the Claude prompt. Finish your question, Return.
3. "Compare Both" asks Claude to diff the two contracts clause by clause.
4. The bottom pane is a full `claude` terminal — anything goes.

First-run walkthrough shows automatically; re-open via Help → Contract Deck
Walkthrough.

## Build
```
./build.sh   # xcodegen + Release build + install to /Applications + launch
```
