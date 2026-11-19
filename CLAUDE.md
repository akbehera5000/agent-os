# AgentOS

Agent OS: a Jarvis-style command center and second brain for every AI tool on
this Mac (Claude Code, Claude, Codex, ChatGPT, Gemini, Antigravity, Copilot,
OpenCode, Qwen, Ollama). Native SwiftUI, no server, no database: it reads the
tools' own files read-only and caches parsed sessions in
`~/Library/Application Support/AgentOS/session-cache.json`.

## Layout

- `Sources/AgentOS/` the app. `App.swift` has the window, menus, and the database location.
- `Sources/AgentOSKit/` rules and data logic with no SwiftUI. Tests in `Tests/AgentOSKitTests/`.
- `Package.swift` a Swift package. There is no Xcode project.
- `build.sh` builds, signs, and installs `~/Applications/AgentOS.app`.
- `Icon/AppIcon.icon` the app icon, an Icon Composer file (JSON plus SVG layers). `build.sh` compiles it with `tools/make_icon.sh`; `tools/icon_review.sh` renders every look into one PNG.
- `docs/` the brief, the screen index, and the user stories, when they exist.

## Build and check

- Build and install: `./build.sh`. Add `--open` to restart the app with the new build. The build shows warnings; fix them.
- Unit tests: `swift test --scratch-path ~/Library/Developer/AgentOS/test-build`.
- Self-test (the app's real functions on a /tmp store): `tools/selftest.sh`. Exit 0 when every check passes. Add a check for every story with logic in `SelfTest.swift`.
- After every UI change, take snapshots with sample data and look at them: `tools/snap.sh`.
  It writes `/tmp/AgentOS-shots/<page>-dark.png` for every sidebar page, and `settings-<tab>-light.png` and `-dark.png` for every Settings tab, then quits. `APP_SNAPSHOT_PAGES=all,settings tools/snap.sh` limits the pages.
  For a panel, sheet, or popover, add a capture to `Snapshot.swift` like the Settings loop.
- Snapshots, seed data, and the self-test refuse to run without `APP_STORE` in /tmp.
- Never test against the real database in `~/Library/Application Support/AgentOS/`.
- Then check the grid: `tools/grid-lint.sh` and `swift tools/check-layout.swift /tmp/AgentOS-shots/*-layout.json`. Both print PASS.
- A change is done when the build has no errors, the grid checks pass, and you looked at the light and dark snapshots.

## Design rules (custom HUD, chosen by the user)

- Dark-only futuristic HUD. Every color, radius, font and motion lives in `UI/Theme.swift` (`HUD`). Never hard-code them in views.
- State colors (on = green, off = red-grey) go on outlines only; pillar hues (skills orange, memory green, routines yellow, apps blue, high purple) are decorative backgrounds.
- Building blocks: `Panel`, `Tag`, `Metric`, `Meter`, `HoverRow`, `IconTile`, `PageHeader`, `EmptyHUD`, `.buttonStyle(.hud(...))`, `.appear(i)`.
- The orb (`UI/OrbView.swift`) is Metal, compiled at runtime: 60 Hz at rest, ProMotion while Jarvis works, 30 Hz in background, paused when hidden. Per-frame motion uses GeometryEffect / Metal, never TimelineView over many views.
- Spacing from `Space` (4 pt grid). Every action has a menu item and shortcut. Reduce Motion is respected by `.appear` and the orbit.
- Data logic lives in `Sources/AgentOSKit` (no SwiftUI). Only `Actions` writes outside the app, always after a confirm.

## Skills

The bama plugin has a skill for each step: `mac-design` (design rules),
`design-system` (accent and tokens), `layout-grid`, `ux-design`,
`swift-swiftui`, `os-integrations`, `performance`, `build-and-verify`,
`test-mac-app`, `app-icon`, `user-stories`, and `improve-loop`. Use them.

## Git

- Commit after each working change, with a message that says what the user can now do.
