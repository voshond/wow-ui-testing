local LIB_ROOT = arg[0]:match("^(.*)/wowtest/addons%.lua$") or "."
package.path = LIB_ROOT .. "/?.lua;" .. LIB_ROOT .. "/?/init.lua;" .. package.path

local Config = require("wowtest.config")

local function Exists(file)
	local handle = io.open(file)
	if handle then handle:close() end
	return handle ~= nil
end

local found, file = pcall(Config.Find, arg[1], Exists)
if not found then os.exit(0) end
local ok, config = pcall(Config.Load, file)
if not ok then
	io.stderr:write(config, "\n")
	os.exit(2)
end
-- name, source, ref, toc: a release zip gives its url and sha256 as source and ref.
for _, addon in ipairs(config.addons) do
	print(table.concat({ addon.name, addon.source or addon.url, addon.ref or addon.sha256, addon.toc or "" }, "\t"))
end
