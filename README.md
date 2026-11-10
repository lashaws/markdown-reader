# Markdown Reader

A tiny, fast, **native macOS app** for reading `.md` files. No Electron, no
dependencies, no internet required — just a thin Swift + WKWebView shell around a
self-contained Markdown renderer.

Set it as the default app for `.md` files and double-click any Markdown file to read
it in a clean, GitHub-style view.

## Features

- **Clean rendered view by default** — headings, lists, tables, task lists,
  blockquotes, fenced code, links, images
- **Rendered / Edit / Side by Side** (toolbar, or ⌘1 / ⌘2 / ⌘3) — Edit shows the
  raw Markdown and lets you change the document in place; Side by Side puts the
  editor on the left and a rendered preview on the right, scrolling together. The
  app remembers the view you last picked.
- **Preview updates on save** — like a Sublime preview, the side-by-side preview
  shows the last saved version and refreshes when you press ⌘S. Turn on
  **View → Live Preview** (⇧⌘L) to have it follow your typing instead.
- **New documents** (⌘N) — launching the app opens an untitled document side by
  side, so you can paste or type Markdown straight away without opening a file.
  Save with ⌘S (or Save As… with ⇧⌘S) to pick where it goes.
- **Copy button on code blocks** — hover a fenced code block and click the
  clipboard icon in its corner to copy the code
- **Command-click links** in the rendered view to open web, email, and local-file
  destinations with their default app
- **Save with ⌘S** — saves back to the file (or prompts for a location for new
  documents); unsaved changes are flagged in the window and prompt before closing.
  Nothing is ever written to disk until you save: there is no autosave
- **Automatic dark / light mode** — follows the system appearance
- **Live reload** — the view updates the instant you save the file (scroll
  position preserved)
- **Find in page** (⌘F) in both Rendered and Edit views — live match highlighting,
  next/previous (Enter / ⇧Enter), match counter, Esc to close
- **Line & word count** badge

## Download

Grab `MarkdownReader-1.1.1-macOS-universal.zip` from
[Releases](https://github.com/lashaws/markdown-reader/releases), unzip it, and drag
**Markdown Reader.app** to `/Applications`. Universal binary — Apple Silicon and Intel,
macOS 11+.

The build is **unsigned**, so Gatekeeper blocks the first launch. Right-click the app →
**Open**, or:

```sh
xattr -dr com.apple.quarantine "/Applications/Markdown Reader.app"
```

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`). No full Xcode needed.

```sh
./build.sh
```

This compiles `Sources/main.swift`, assembles `Markdown Reader.app`, ad-hoc signs it,
and registers it with LaunchServices. Pass `--universal` to build a fat arm64 + x86_64
binary (what the releases ship).

## Run

```sh
open -a "$PWD/Markdown Reader.app" sample.md
```

Or double-click `Markdown Reader.app` in Finder. (First launch: if Gatekeeper warns
about an unidentified developer, right-click the app → **Open**.)

## Set as the default Markdown app

Right-click any `.md` file → **Get Info** → **Open with** → **Markdown Reader** →
**Change All…**

## Project layout

| Path                    | Purpose                                          |
|-------------------------|--------------------------------------------------|
| `Sources/main.swift`    | Native app: windows, toolbar, menus, file watch  |
| `Resources/viewer.html` | Renderer, syntax highlighter, find, styling       |
| `Info.plist`            | Bundle metadata + `.md` document-type registration |
| `build.sh`              | Build script                                     |

## License

MIT
