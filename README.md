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
luajit wowtest/cli.lua -j               all specs, one process per CPU
luajit wowtest/cli.lua runner/          only spec/runner/
luajit wowtest/cli.lua -t "full health" only tests whose name contains the text
luajit wowtest/cli.lua --tag shields    only tests tagged #shields
luajit wowtest/cli.lua --times          also time each spec file
```

A run that selects no tests fails. Lua 5.1 works as well as LuaJIT, except for
specs that load the BLP decoder.

## Configuring wowtest

`wowtest/cli.lua` reads `wut.config.lua` (or `tests/wut.config.lua`, or the
file given with `--config`) from the directory it runs in:

```lua
return {
	specs = {
		{ dir = "tests/spec/" },
		{ dir = "MyLib/spec/", prefix = "mylib/" },
	},
	pattern = "*_spec.lua",
	path = { "./tests/?.lua" },
	setup = "tests/setup.lua",
	syntax = { include = { "MyAddon" }, exclude = { "*/Libs/*" } },
}
```

- `specs`: spec dirs; a `prefix` names the dir's files in output and filters.
- `pattern`: spec file name pattern.
- `path`: entries prepended to `package.path`. The library root is always on
  it, so specs can `require("wowproof")` from a fetched copy.
- `setup`: a file run once per process before any spec file.
- `syntax`: Lua files loaded (not run) on every run, to catch syntax errors in
  code no spec touches.

## Using wowmock

```lua
local Mock = require("wowmock")
local Loader = require("wowmock.loader")

Mock.Extend("MyAddon", {
	globals = { "MyAddon", "MyAddonDB" },
	install = function(mock) _G.LibStub = MyLibStubStandIn end,
	installUI = function(mock) end,
})
Mock.Install()
Mock.InstallUI()
Loader.Skip({ "Libs/SomeLib/" })
local ns = Loader.LoadToc("MyAddon/MyAddon.toc", "MyAddon")
Mock.FireEvent("ADDON_LOADED", "MyAddon")
Mock.RunTimers()
```

- `Mock.Install()` resets the client; `Mock.InstallUI()` adds client UI and a
  unit API that returns secrets. Extensions are kept by name: their `globals`
  are cleared on every install and their steps run before the API is enforced.
- Every widget method and documented global is checked against the snapshot
  in `wowmock/snapshots/` (`Mock.API`): undocumented methods, missing
  arguments, refused secrets and protected calls in combat raise errors.
  `Mock.API.UseSnapshot(path)` switches builds.
- Widgets keep their state in `obj.__state` and record unimplemented calls in
  `obj.__calls`; `wowproof.adapters.mock_state` renders them.
- `wowmock/api.lua` is plain Lua 5.1 without ffi, so other Lua hosts can
  `dofile` it and check their own mocks against the same snapshot.

Regenerate a snapshot from a wow-ui-source checkout with
`luajit scripts/api-snapshot.lua [source dir] [output]`.

## Adopting in an addon

1. Copy `scripts/fetch-wut.sh` into the addon repo and pin the library:

   ```sh
   echo "<full commit SHA> # v0.1.0" > .wut-version
   echo ".wut/" >> .gitignore
   ```

2. Add `wut.config.lua` (or `tests/wut.config.lua`), see
   [Configuring wowtest](#configuring-wowtest). Third-party addons the addon
   runs inside go in `addons`, pinned by a git commit, or by URL and sha256
   for addons that only ship release zips:

   ```lua
   addons = {
   	{ name = "Titan", source = "owner/repo", ref = "<full commit SHA>", toc = "Titan/Titan.toc" },
   	{ name = "Other", url = "https://example.com/Other.zip", sha256 = "<64 hex digits>", toc = "Other/Other.toc" },
   },
   ```

   A release zip is checked against its sha256 and unzipped as it is. A repo
   without a config file needs no Lua to fetch.

3. Fetch and run:

   ```sh
   lib="$(bash scripts/fetch-wut.sh)"
   luajit "$lib/wowtest/cli.lua" -j
   ```

   `fetch-wut.sh` puts the library in `.wut/` and each addon in
   `.wut/addons/<name>/`, and does nothing when they already match their pins.
   It prints the library folder on stdout (and the `package.path` on stderr).
   While working on the library, `WUT_DIR=../wow-ui-testing` uses that checkout
   instead.

4. In specs, load third-party addons before the addon under test:

   ```lua
   local Loader = require("wowmock.loader")
   Loader.LoadAddon("Titan")
   Loader.LoadToc("MyAddon/MyAddon.toc", "MyAddon")
   ```

   `LoadAddon` loads the entry's `toc` (default `<name>.toc`), preferring the
   client's flavour TOCs (`Loader.tocSuffixes`: `_Vanilla`, `-Vanilla`,
   `_Classic`, `-Classic`). XML files load like the client's: scripts and
   includes in document order, virtual frames as templates `CreateFrame` can
   inherit, other frames built with their layers, anchors and scripts. A host
   can add its own Lua templates to `Mock.templates` (`name -> function(frame)`).

5. In CI, cache `.wut` keyed on the pins. The library is public, so the fetch
   needs no secret; the job's own token only spares GitHub's anonymous rate
   limit:

   ```yaml
   - uses: actions/cache@v4
     with:
       path: .wut
       key: wut-${{ hashFiles('.wut-version', 'wut.config.lua', 'tests/wut.config.lua') }}
   - run: bash scripts/fetch-wut.sh
     env:
       GITHUB_TOKEN: ${{ github.token }}
   ```

## Client data

`clientdata/forever.json` pins everything taken from the client for one
build: the build and interface number, the Gethe/wow-ui-source commit, the
Gethe/wow-ui-textures art ref, and the checksums of the wago.tools
UiTextureAtlas exports. Generated from it:

- `wowmock/snapshots/forever-<build>.lua`, the API snapshot
  (`scripts/api-snapshot.lua`)
- `clientdata/atlases/forever-<build>.lua`, an atlas table
  (`scripts/atlas_catalog.py`)

The full atlas table is about 17k atlases and 3.3 MB, too large to commit, so
the lib only commits the atlases wowmock and its fixtures use. Hosts keep their
own pinned subset, generated from the names their Lua uses:

```sh
python3 -B .wut/scripts/atlas_catalog.py --fetch --scan 'MyAddon/**/*.lua' --output tests/proof/atlases.lua
```

`bash scripts/update-client-source.sh --sync` checks out the pinned
wow-ui-source into the gitignored `.client-source/forever` (CI does this, and
the API contract spec then regenerates the snapshot and compares it).

## Bumping the client build

1. `bash scripts/update-client-source.sh [commit]` (default: the newest
   commit of the pin's branch; `ART_REF=<sha>` also repins the art). It syncs
   `.client-source/forever`, rewrites `clientdata/forever.json`, points
   `wowmock/api.lua` at the new snapshot, regenerates the snapshot and
   downloads the new build's atlas exports to repin and regenerate the table.
2. Review the snapshot diff: it is the client API change list. Fix the mock
   where `luajit wowtest/cli.lua -j` now fails.
3. Remove the previous build's snapshot and atlas table once no addon pins a
   lib version that needs them.
4. Commit, tag a new minor version, and bump `.wut-version` in each addon;
   regenerate their atlas subsets with `--scan`.

## License

[PolyForm Noncommercial 1.0.0](LICENSE).
