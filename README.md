# Markdown Reader

A tiny, fast, **native macOS app** for reading `.md` files. No Electron, no
dependencies, no internet required — just a thin Swift + WKWebView shell around a
self-contained Markdown renderer.

Set it as the default app for `.md` files and double-click any Markdown file to read
it in a clean, GitHub-style view.

## Features

- **Clean rendered view by default** — headings, lists, tables, task lists,
  blockquotes, fenced code, links, images
- **Rendered / Source toggle** (toolbar, or ⌘1 / ⌘2) — Source shows the raw
  Markdown with syntax coloring
- **Automatic dark / light mode** — follows the system appearance
- **Live reload** — the view updates the instant you save the file (scroll
  position preserved)
- **Find in page** (⌘F) — live match highlighting, next/previous (Enter / ⇧Enter),
  match counter, Esc to close
- **Line & word count** badge

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`). No full Xcode needed.

```sh
./build.sh
```

This compiles `Sources/main.swift`, assembles `Markdown Reader.app`, ad-hoc signs it,
and registers it with LaunchServices.

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
