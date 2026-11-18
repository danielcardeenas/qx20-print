# `qx20` — command line

`qx20` prints on a Canon SELPHY QX20 from the terminal, for people, scripts and
AI agents. It ships inside **QX20 Print.app** and shares its settings (printer
key, network, paper) with the app.

## Install

- **From the app:** `./build-app.sh --install` links `qx20` into `/usr/local/bin`
  (or `~/.local/bin` when that isn't writable).
- **From a downloaded release:** move the app to *Applications*, then
  ```bash
  ln -s "/Applications/QX20 Print.app/Contents/MacOS/qx20" /usr/local/bin/qx20
  ```

Run it from that location (the link is fine): macOS can't verify a binary
inside your home folder, so it would never get the Location permission.

## First run

```bash
qx20 setup                      # asks for Location access, checks the key, lists printers
qx20 config set key ABCDEFGHI   # the 9-character key printed inside the ink cassette cover
```

The **Location permission** is needed because macOS only shows Wi-Fi network
names to apps that have it; `qx20` never reads your location. macOS checks the
permission of the app that contains the tool, **QX20 Print**: `qx20 setup`
opens the app so you can allow it once, and waits until it works. If you can't
grant it, join the printer's Wi-Fi yourself and use `--no-switch`.

## Commands

| Command | What it does |
|---|---|
| `qx20 print <image>... [options]` | Print. One sheet per image unless `--together` or `--per-sheet` |
| `qx20 preview <image>... -o <file.png\|dir>` | Render the sheets to PNG without printing |
| `qx20 status` | Printer model, paper/ink and error state |
| `qx20 scan` | Nearby QX20 printers (doesn't change Wi-Fi) |
| `qx20 setup` | First-time check: permission, key, nearby printers |
| `qx20 config [show]` · `config set <name> <value>` · `config unset <name>` | Settings: `key`, `network`, `paper`, `return` |

Images: JPEG, PNG (transparency kept), HEIC, WebP, SVG (rasterized at print size)…

### Sheet options (`print`, `preview`)

| Option | |
|---|---|
| `--paper card\|square` | Paper (default: saved setting, else `card`) |
| `--fit` / `--fill` | Whole image (default) / cover the sheet or cell, cropping |
| `--margin MM` | Extra white margin |
| `--together` | All images on one sheet, auto-arranged |
| `--per-sheet N` | N images per sheet (grid) |
| `--repeat` | With `--per-sheet`: repeat images to fill every cell (stickers) |
| `--gap MM` | Space between images (default 1.5) |
| `--no-rotate` | Don't rotate images to use the space better |
| `--guides` | Thin grey cut guides |
| `--copies N` | Print each sheet N times |

### Printer options (`print`, `status`)

| Option | |
|---|---|
| `--no-switch` | Don't change Wi-Fi: the Mac is already on the printer's network |
| `--stay` | Stay on the printer's Wi-Fi afterwards |
| `--network SSID` | Printer network (default: saved, else the strongest `QX20-…`) |
| `--key KEY` | Printer key (default: saved) |
| `--size-code N` | Media code (square paper isn't verified yet) |

By default `qx20 print` joins the printer's Wi-Fi, prints and returns the Mac
to its usual network (offline for about a minute per sheet).

## For scripts and AI agents

Use `--json`: stdout gets one JSON object per line; the **last line is always
the result**, with `ok`, a stable `code` and the `exit` status.

```bash
$ qx20 print photo.jpg --json
{"event":"log","message":"1 sheet(s) on card paper"}
{"event":"status","message":"Connecting to QX20-ABC…"}
{"event":"sheet_started","index":1,"name":"photo.jpg","total":1}
{"event":"status","message":"Printing yellow","progress":0.25}
…
{"event":"sheet_finished","index":1,"ok":true}
{"code":"ok","event":"result","exit":0,"failed":0,"ok":true,"printed":1}
```

Errors include a `hint` with the next step:

```json
{"code":"printer_error","error":"The printer reported an error (state 0x0C)…","event":"result","exit":3,"hint":"Check paper and ink cassette, then turn the printer off and on.","ok":false}
```

### Exit codes

| Exit | `code` | Meaning / what to do |
|---|---|---|
| 0 | `ok` | Done |
| 1 | `some_failed` | Some sheets failed (see `sheet_finished` events) |
| 2 | `usage` | Bad arguments or unreadable image |
| 3 | `printer_error` | The printer stopped (usually no paper): load paper, power-cycle, retry |
| 4 | `unreachable` | Printer off / Wi-Fi failed: turn it on, or join its Wi-Fi and use `--no-switch` |
| 5 | `not_configured` | No key, or the printer refused it: `qx20 config set key <KEY>` (case-sensitive) |
| 6 | `location_permission` | Run `qx20 setup` and allow Location, or use `--no-switch` |

### Recipes

```bash
qx20 status --json                                   # is it ready?
qx20 preview photo.jpg -o /tmp/check.png             # look before printing
qx20 print photo.jpg --json                          # one photo
qx20 print a.jpg b.jpg --together --guides           # two on one sheet, to cut
qx20 print logo.svg --per-sheet 6 --repeat --guides  # sticker sheet
qx20 print *.jpg --per-sheet 4 --copies 2            # contact sheets, twice
```

Notes for agents:
- Printing takes ~1 minute per sheet and the Mac is offline meanwhile (it is
  on the printer's Wi-Fi). Don't run commands that need the internet in
  parallel.
- Remove each print from the output slot when it's done.
- Messages follow the system language (English or Spanish); rely on `code`.
