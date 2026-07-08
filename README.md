# app-router

A lightweight, local-first macOS router for files and URLs — a slim alternative to OpenIn 4. When you open a file or a link, app-router picks the destination from a single JSONC config: a specific app for a file extension, or a specific browser (and Chrome profile) for a URL. When more than one destination matches, it shows a cursor-aligned popup you can drive with the mouse, the arrow keys, or number keys.

No settings GUI, no background bloat. The entire configuration is one hot-reloaded JSONC file you can back up, diff, and version like any other dotfile.

## Features

- **Extension routing** — map a file extension to one or more apps or shell executables.
- **URL routing** — route URLs to a browser or a specific Chrome/Chromium profile using regex rules.
- **Cursor popup selector** — appears only when two or more targets match; mouse, ↑/↓ navigation, and 1–9 direct selection, all handled locally (no Accessibility permission required).
- **JSONC config** — comments allowed; validated and **hot-reloaded** on save.
- **Atomic reloads** — a bad edit is rejected as a whole and the last-known-good config stays active, so a typo never breaks routing.
- **No shell** — every target is executed as an argv array via `Process`; the file path or URL is always a discrete argument, so nothing in the config can be interpreted as shell syntax.
- **Headless CLI harness** — `--route` resolves and prints targets without opening anything, so configs are testable end-to-end.

## Requirements

- macOS 14 or later
- Swift 6 toolchain (Xcode 16+) to build from source

## Build

```sh
swift build -c release
```

The product is `app-router` (a menu-bar helper) in `.build/release/`.

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
app-router --config <path>        # use an alternate config file
app-router --help
```

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
| `system: true` | the macOS default handler | `open <input>` |

### Routing policy

- **0 matches** → the configured `default` fallback, or a surfaced no-route error if none is set.
- **1 match** → opens immediately, no popup.
- **2+ matches** → the cursor-aligned popup selector.

### Handled types

macOS Launch Services cannot make an app the default handler for a type it did not declare at build time. app-router declares its handled document types and URL schemes in its `Info.plist`; the router routes among **declared** extensions/UTIs and schemes. Adding a new type requires an app update and re-registration. Becoming a default handler is an explicit, user-initiated menu action — never automatic.

## Architecture

- `AppRouterCore` — platform-agnostic domain logic (JSONC preprocessor, config model + validation, routing engine, target→argv resolver, hot-reload store). No AppKit, no I/O; 100% headlessly tested.
- `AppRouter` — the macOS shell: AppKit menu-bar UI, the borderless popup panel, the `Process`/Launch Services adapters, the filesystem watcher, and the CLI.

Run the test suite with:

```sh
swift test
```

## License

[MIT](LICENSE) © Josh Glazer
