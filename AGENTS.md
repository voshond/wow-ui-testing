# Agent notes

- This is a library used by several addon repos. Nothing in `wowproof/`,
  `wowtest/`, `wowmock/` or `clientdata/` may name an addon that uses it;
  `wowproof/spec/package_spec.lua` fails if one does.
- Code is Lua 5.1 compatible. Only `wowproof/blp.lua` (and anything that
  requires it) may use LuaJIT's ffi. Anything MagicMap loads through lupa
  (the API snapshot and its contract) must stay plain Lua 5.1.
- Run the specs from the repository root with `luajit wowtest/cli.lua -j`
  (see `luajit wowtest/cli.lua --help` for filters).
- Generated output (`.proof/`, `.proof-art/`, `.client-source/`) is never committed.
- Client build pins live in `clientdata/<flavor>.json`; bump them only with
  `scripts/update-client-source.sh` (see README, Bumping the client build).
- Consumers pin commit SHAs; tag releases with semver (`v0.1.0`) for humans and
  keep changes backwards compatible within a minor version.
- License: PolyForm Noncommercial 1.0.0.
