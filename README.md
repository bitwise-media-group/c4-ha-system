# c4-ha-system

Control4 DriverWorks drivers that integrate [Home Assistant](https://www.home-assistant.io/) devices into Control4. All
drivers in this mono-repo are versioned and released together.

| Driver                                        | Purpose                                                                                                                          |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **Home Assistant Gateway** (`ha-gateway.c4z`) | System driver owning a secure websocket session to Home Assistant. One per project.                                              |
| **Home Assistant Cover** (`ha-cover.c4z`)     | Represents one HA `cover` entity (shade, blind, curtain, shutter, awning, garage door, gate) as a Control4 blind. One per cover. |

## Architecture

```text
Home Assistant  <── wss / TLS ──>  ha-gateway  <── C4 control binding ──>  ha-cover (xN)
 (nginx + Let's Encrypt OK)         (combo,        targeted routing by         (blind proxy)
                                     singleton)    entity_id
```

- The gateway authenticates with a long-lived access token over the
  [HA websocket API](https://developers.home-assistant.io/docs/api/websocket), seeds state with `get_states`, and
  subscribes to `state_changed` — device state stays in sync even when covers are moved from the HA UI, automations, or
  the wall switch.
- Device drivers auto-bind to the gateway (binding class `HOMEASSISTANT`) and register the entities they represent; the
  gateway routes each state change only to the drivers that registered it.
- Service calls flow the other way: proxy commands (`SET_LEVEL_TARGET`, stop, …) become `cover.open_cover` /
  `close_cover` / `set_cover_position` / `stop_cover` (or their tilt equivalents for tilt-only covers).
- The cover driver adapts to the entity's `supported_features`: positional 0–100 control when available, plain
  open/close otherwise (garage doors, gates), stop when supported, and tilt services for tilt-only covers. The HA
  `device_class` is surfaced as a read-only property; pick the display type (shade, awning, door, …) on the blind
  proxy's own pulldown in Composer.

### TLS

TLS peer verification is on by default and validated against the bundled ISRG root certificates (`certs/isrg-root.pem`),
so an HA instance behind **nginx with a Let's Encrypt certificate** works out of the box (`Use SSL = Yes`,
`Port = 443`). Set `Verify Certificate = No` for self-signed certificates. Hostname verification is not performed by the
controller's TLS stack — verification is chain-of-trust only.

The access token is stored encrypted on the controller (`C4:PersistSetValue(..., true)`) and the property field is
masked after saving; it is never logged.

Known-benign log noise: whenever the websocket (re)connects, director.log shows
`DeviceStreamConnection::setCertificate ... No certificate was specified` and the matching `setPrivateKey` line for the
gateway's binding. Director always probes for a mutual-TLS **client** certificate on SSL connections; Home Assistant
does not use client certificates, and server-side verification is unaffected.

## Installation

1. Grab `ha-gateway.c4z` and `ha-cover.c4z` from the latest [release](../../releases), or build them with
   `sh scripts/build.sh`.
2. In ComposerPro, install both via Driver &gt; Add or Update Driver.
3. Add **Home Assistant Gateway** to the project (it is a singleton). Set `Host`, `Port`, `Use SSL`, and paste a
   long-lived access token (HA → Profile → Security). `Status` shows `Connected` when the websocket authenticates; the
   `Test Connection` action checks the REST API and token independently.
4. Add a **Home Assistant Cover** per cover entity. It binds to the gateway automatically; pick the entity from the
   `Entity Selector` dropdown (populated live from HA) or type the `entity_id`. Set `Travel Time` roughly to the cover's
   full travel time so interfaces animate movement accurately.

### Programming

- Gateway events: `Home Assistant Connected` / `Home Assistant Disconnected`.
- Gateway command `Call Service`: invoke any HA service from Composer programming (`Service` = `domain.service`,
  optional `Entity ID`, optional JSON `Data`).
- The blind proxy exposes the standard blind events and variables (Opening, Closing, Level, …) for the cover drivers.

## Repository layout

```text
drivers/<name>/       driver.xml, driver.lua, .c4zproj per driver
lib/ha/               shared Lua modules vendored into every .c4z at build time
certs/                ISRG roots for TLS peer verification
scripts/build.sh      assembles dist/<name>.c4z, stamps the shared version
scripts/test.sh       runs the test suites (luajit or lua5.1)
tests/                C4-stubbed unit/integration tests for the protocol logic
.mise/                shared toolchain submodule (pinned tools, task archetypes)
```

## Development

Tooling is pinned through [mise](https://mise.jdx.dev) via the shared toolchain submodule (`git submodule update --init`
after cloning; `brew install mise`). The Makefile is a thin forwarder — `make <task>` is `mise run <task>`:

```sh
make fmt     # stylua + prose format + SPDX license headers
make lint    # selene + stylua --check + prose/shell/container/license checks
make build   # produce dist/*.c4z
make test    # run the C4-stubbed test suites
make pr      # the full local gate: fmt, lint, build, test, commit
```

Lua tools: [StyLua](https://github.com/JohnnyMorganz/StyLua) formats, [selene](https://github.com/Kampfkarren/selene)
lints against the Control4 environment declared in `c4.yml`, and tests run under the pinned Lua 5.1 (exercising the
pure-Lua `ha.bits` fallback; a local luajit exercises the native path).

Versioning: [Conventional Commits](https://www.conventionalcommits.org/) drive
[release-please](https://github.com/googleapis/release-please); `version.txt` holds the semver, and the build stamps
every `driver.xml` with `major*10000 + minor*100 + patch` (Control4 driver versions are plain integers). Releases attach
the built `.c4z` files.

Requires Control4 OS 3.3.0+ (dynamic list properties) for the cover driver; the gateway runs on 3.0.0+.

## Roadmap

- Additional device drivers (lights, locks, sensors, switches…) versioned in this repo.
- Keypad button-link bindings on the cover driver.
- Optional relay+contact garage pattern as an alternative to the blind proxy `Door` type.
