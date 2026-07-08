# app-router

A lightweight, local-first macOS router for files and URLs — a slim alternative to OpenIn 4. When you open a file or a link, app-router picks the destination from a single JSONC config: a specific app for a file extension, or a specific browser (and Chrome profile) for a URL. When more than one destination matches, it shows a cursor-aligned popup you can drive with the mouse, the arrow keys, or number keys.

No settings GUI, no background bloat. The entire configuration is one hot-reloaded JSONC file you can back up, diff, and version like any other dotfile.

## Features

- **Extension routing** — map a file extension to one or more apps or shell executables.
- **URL routing** — route URLs to a browser or a specific Chrome/Chromium profile using regex rules.
- **Cursor popup selector** — appears only when two or more targets match; mouse, ↑/↓ navigation, and 1–9 direct selection, all handled locally (no Accessibility permission required).
- **JSONC config** — comments allowed; validated and **hot-reloaded** on save.
- **Atomic reloads** — a bad edit is rejected as a whole and the last-known-good config stays active, so a typo never breaks routing. The file watcher survives atomic/editor "save-as-replace" writes (vim, most editors) and coalesces a burst of save events into a single reload.
- **Non-blocking errors** — reload and startup config failures surface through the menu-bar item (and a notification), never a modal that seizes the app.
- **No shell** — every target is executed as an argv array via `Process`; the file path or URL is always a discrete argument, so nothing in the config can be interpreted as shell syntax.
- **Loop-safe system fallback** — a `system: true` target dispatches to the handler that owned the type *before* app-router registered itself, so making app-router the default handler can't create an open→app-router→open routing loop.
- **Headless CLI harness** — `--route` resolves and prints targets without opening anything, so configs are testable end-to-end. Malformed CLI usage is a hard error, never a stray GUI launch.
- **Unified logging** — route decisions, reload results, and registration outcomes are logged under subsystem `com.jsglazer.app-router` (view with `log stream --predicate 'subsystem == "com.jsglazer.app-router"'`).

## Requirements

- macOS 14 or later

## Install

1. Download **`app-router-<version>.dmg`** from the [latest release](https://github.com/jsglazer/app-router/releases/latest).
2. Open the DMG and drag **app-router** onto the **Applications** shortcut.
3. Launch it from Applications. It runs as a menu-bar helper (a `⇄` item, no Dock icon).
4. Use the menu-bar item → **Register as Default Handler…** to have macOS route file/URL opens through app-router.

That's it — a real `.app` bundle is what lets macOS deliver Finder/browser open events and lets app-router register as a default handler, and the DMG ships exactly that.

> The released DMG is signed with a Developer ID and notarized, so it opens with a normal double-click. A locally built, ad-hoc-signed DMG will prompt Gatekeeper on first launch — right-click the app ▸ **Open** once to approve it.

## Build from source

Requires the Swift 6 toolchain (Xcode 16+).

```sh
git clone https://github.com/jsglazer/app-router.git
cd app-router
Scripts/make-dmg.sh          # -> dist/app-router-<version>.dmg (build + bundle + sign + package)
```

`Scripts/make-dmg.sh` builds the release binary, wraps it in the `.app` bundle, code-signs it, and produces the drag-to-Applications DMG. It adapts to your keychain automatically:

| What's in your keychain | Result |
| --- | --- |
| A **Developer ID Application** identity + a notarytool profile (`app-router-notary`) | Hardened-runtime signed, **notarized & stapled** |
| A Developer ID identity only | Hardened-runtime signed (not notarized) |
| Neither | **Ad-hoc** signed — fine for local use |

Override detection with `SIGN_IDENTITY=…`, `NOTARY_PROFILE=…`, or `SKIP_NOTARIZE=1`. Regenerate the app icon with `Scripts/make-icon.sh`.

For CLI-only use you can skip packaging entirely — `swift build -c release` drops a bare `app-router` binary in `.build/release/` that runs `--route`, `--validate`, etc. directly. Run the test suite with `swift test`.

## Usage

Launch the app to run as a menu-bar helper. On first run it writes a starter config to:

```
~/.config/app-router/config.jsonc
```

Edit that file and save — the app validates and reloads it automatically. Use the menu-bar item to reveal the config in Finder or to register app-router as a default handler.

### CLI

```sh
app-router --route <url|path>     # print the resolved target(s) without opening anything
app-router --test-url <url|path>  # alias of --route
app-router --validate             # validate the config and exit (non-zero on error)
app-router --config <path>        # use an alternate config file (also honored for GUI launch)
app-router --help
```

An unrecognized flag, or a flag missing its value, prints usage to stderr and exits `64` (`EX_USAGE`) — it never falls through to launching the GUI. Running with no CLI flags launches the menu-bar helper.

`--route` is the headless harness — it prints each resolved target and the exact argv that would be executed:

```
$ app-router --route https://github.com/foo
SINGLE for url https://github.com/foo
  Chrome — Work
  argv: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--profile-directory=Profile 1", "https://github.com/foo"]
```

## Configuration

The config is JSONC (JSON with `//` and `/* */` comments). Comment delimiters inside string values — e.g. `http://` or a regex — are preserved.

```jsonc
{
  // File extension -> ordered candidate targets. Two or more => cursor popup.
  "extensions": {
    "md": [
      { "name": "mdView",       "app": "/Applications/mdView.app" },
      { "name": "Sublime Text", "app": "/Applications/Sublime Text.app" }
    ],
    "sh": [
      { "name": "Run",          "exec": "/usr/local/bin/handle", "args": ["--verbose"] }
    ]
  },

  // URL rules: a regex tested against the URL. Every matching rule contributes targets.
  "urls": [
    {
      "match": "github\\.com",
      "targets": [
        { "name": "Chrome — Work", "browser": "/Applications/Google Chrome.app", "profile": "Profile 1" }
      ]
    }
  ],

  // Optional fallback when nothing matches. system:true defers to the macOS default handler.
  "default": { "name": "System Default", "system": true }
}
```

### Target kinds

A target names exactly one destination:

| Field | Meaning | Executed as |
| --- | --- | --- |
| `app` | GUI application bundle | `open -a <app> <input>` |
| `exec` (+ optional `args`) | shell executable / script | `<exec> <args…> <input>` |
| `browser` | browser bundle | `open -a <browser> <input>` |
| `browser` + `profile` | browser with a Chrome/Chromium profile | `<browser-binary> --profile-directory=<id> <input>` |
| `system: true` | the macOS default handler | `open <input>`, or `open -b <previous-handler>` when app-router is itself the default (loop-safe) |

Paths for `app`, `exec`, `browser`, and `bin` must be **absolute** (start with `/`); a relative path is rejected at validation time with a clear message rather than failing silently at launch.

### Routing policy

- **0 matches** → the configured `default` fallback, or a surfaced no-route error if none is set.
- **1 match** → opens immediately, no popup.
- **2+ matches** → the cursor-aligned popup selector.

### Handled types

macOS Launch Services cannot make an app the default handler for a type it did not declare at build time. app-router declares its handled document types and URL schemes in its `Info.plist`; the router routes among **declared** extensions/UTIs and schemes. Adding a new type requires an app update and re-registration. Becoming a default handler is an explicit, user-initiated menu action — never automatic; it runs off the main thread and reports how many types were registered, skipped, or failed. (Registration works out of the box when you install the `.app` from the DMG — see [Install](#install).)

## Architecture

- `AppRouterCore` — platform-agnostic domain logic (JSONC preprocessor, config model + validation, routing engine, target→argv resolver, hot-reload store). No AppKit, no I/O; 100% headlessly tested.
- `AppRouter` — the macOS shell: AppKit menu-bar UI, the borderless popup panel, the `Process`/Launch Services adapters, the filesystem watcher, and the CLI.

Run the test suite with:

```sh
swift test
```

## License

[MIT](LICENSE) © Josh Glazer
