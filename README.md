# wow-ui-testing

Shared test and UI-proof tooling for World of Warcraft addons. Addon repos pin
one commit of this library and fetch it into a gitignored `.wut/` folder, so
every addon tests against the same runner, the same mocked client and the same
Blizzard client data.

## Packages

| Package | What it is |
| --- | --- |
| `wowproof/` | Renders the frame tree of a mocked client to SVG, PNG and an HTML contact sheet. Talks to widgets only through adapters. See [wowproof/README.md](wowproof/README.md). |
| `wowtest/` | A busted-style spec runner for LuaJIT and Lua 5.1 (describe / it / before_each / after_each, path, name and tag filters, parallel runs), configured per addon by a `wut.config.lua`. |
| `wowmock/` | A mocked WoW client that loads an addon through its TOC, fires events and timers, and is held to a generated snapshot of Blizzard's documented client API. |

`clientdata/` pins the Blizzard client build the mock and the proof art follow
(Gethe/wow-ui-source, Gethe/wow-ui-textures, wago.tools exports), so a client
build bump happens once for every addon.

## Requirements

- LuaJIT (the BLP decoder in `wowproof` uses its ffi); Lua 5.1 runs everything else
- `rsvg-convert` (librsvg) for PNG proof, ImageMagick for `.tga`/`.blp` textures

## Running the specs

```sh
luajit spec/bootstrap.lua
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE).
