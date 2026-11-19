# Contributing to Agent OS

Thanks for helping! Agent OS is a native SwiftUI + Metal app with no server and no database.

## Build and run

```bash
./build.sh --open          # builds, signs ad hoc, installs to /Applications/Agent OS.app and opens it
APP_DEMO=1 "/Applications/Agent OS.app/Contents/MacOS/AgentOS"   # run with fictional demo data
```

## Before you open a PR

```bash
swift test --scratch-path ~/Library/Developer/AgentOS/test-build   # unit tests (AgentOSKit)
tools/selftest.sh                                                   # in-app self-test, must print SELFTEST PASS
APP_DEMO=1 tools/snap.sh                                            # screenshots of every page into /tmp/AgentOS-shots
```

## Where things live

- `Sources/AgentOSKit/` – scanners, pricing, brain graph, routines. No SwiftUI, fully unit-tested.
- `Sources/AgentOS/` – the app: pages, Jarvis, the Metal brain renderer (`UI/BrainView.swift`).
- `UI/Theme.swift` – every color, font and animation (`HUD`). Don't hard-code styles in views.

## Adding support for another AI tool

Add a `ToolSpec` to `Sources/AgentOSKit/ToolCatalog.swift` (app path, config folder, skills folder, MCP config format, rules file). If the tool keeps session logs, add a parser next to `parseClaude` / `parseCodex` in `Scanner.swift` and a unit test with a tiny fixture.

## Ground rules

- Agent OS reads other apps' files **read-only**. Anything that writes outside the app goes through `Actions` and is triggered by an explicit button with a confirmation.
- No telemetry, no network calls except the daily exchange rate and model downloads the user starts.
