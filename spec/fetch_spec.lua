local Config = require("wowtest.config")
local Quote = Config.Quote

local function Shell(command)
	local handle = io.popen("bash -c " .. Quote(command .. " 2>&1; echo \"exit=$?\""))
	local output = handle:read("*a")
	handle:close()
	return output, tonumber(output:match("exit=(%d+)%s*$"))
end

local function Read(path)
	local handle = io.open(path)
	if not handle then return nil end
	local text = handle:read("*a")
	handle:close()
	return text
end

local function Write(path, text)
	local handle = assert(io.open(path, "w"))
	handle:write(text)
	handle:close()
end

local function Has(text, part)
	return text:find(part, 1, true) ~= nil
end

local GIT = "git -c user.name=wut -c user.email=wut@example.invalid"

local function Repo(dir, copy)
	local output, code = Shell("mkdir -p " .. Quote(dir) .. " && cp -R " .. copy .. " " .. Quote(dir) .. " && cd " .. Quote(dir)
		.. " && git init -q && git add -A && " .. GIT .. " commit -q -m fixture && git rev-parse HEAD")
	assert.equals(0, code, output)
	return output:match("(%x+)%s*exit=")
end

describe("fetch-wut.sh", function()
	local scratch, lib, libSha, addonSha, consumer, script

	before_each(function()
		scratch = io.popen("mktemp -d"):read("*l")
		script = Quote(io.popen("pwd"):read("*l") .. "/scripts/fetch-wut.sh")
		lib = scratch .. "/lib"
		libSha = Repo(lib, "wowtest")
		addonSha = Repo(scratch .. "/panel", "spec/fixtures/addons/Panel/Panel")
		consumer = scratch .. "/consumer"
		os.execute("mkdir -p " .. Quote(consumer))
		Write(consumer .. "/.wut-version", "# wow-ui-testing\n" .. libSha .. " # v0.1.0\n")
		Write(consumer .. "/wut.config.lua", string.format([[return {
	specs = { "tests/spec" },
	addons = { { name = "Panel", source = %q, ref = %q, toc = "Panel/Panel.toc" } },
}]], scratch .. "/panel", addonSha))
	end)

	after_each(function()
		os.execute("rm -rf " .. Quote(scratch))
	end)

	local function Fetch(env)
		return Shell("(cd " .. Quote(consumer) .. " && env -u WUT_DIR WUT_SOURCE=" .. Quote(lib) .. " " .. (env or "")
			.. " bash " .. script .. " 2>" .. Quote(scratch .. "/stderr") .. ")")
	end

	it("fetches the pinned library and addons, then leaves them alone", function()
		local output, code = Fetch()
		assert.equals(0, code, output .. (Read(scratch .. "/stderr") or ""))
		assert.is_true(Has(output, consumer .. "/.wut\n"), output)
		assert.equals(libSha .. "\n", Read(consumer .. "/.wut/.wut-ref"))
		assert.is_not_nil(Read(consumer .. "/.wut/wowtest/cli.lua"))
		assert.equals(addonSha .. "\n", Read(consumer .. "/.wut/addons/Panel/.wut-ref"))
		assert.equals("Panel/Panel.toc\n", Read(consumer .. "/.wut/addons/Panel/.wut-toc"))
		assert.is_not_nil(Read(consumer .. "/.wut/addons/Panel/Panel/Panel_Vanilla.toc"))
		assert.is_true(Has(Read(scratch .. "/stderr"), "package.path: " .. consumer .. "/.wut/?.lua"))

		Write(consumer .. "/.wut/marker", "kept")
		Write(consumer .. "/.wut/addons/Panel/marker", "kept")
		output, code = Fetch()
		assert.equals(0, code, output)
		local stderr = Read(scratch .. "/stderr")
		assert.is_true(Has(stderr, "library " .. libSha .. " already in .wut"), stderr)
		assert.is_true(Has(stderr, "addon Panel " .. addonSha .. " already in .wut/addons"), stderr)
		assert.equals("kept", Read(consumer .. "/.wut/marker"))
		assert.equals("kept", Read(consumer .. "/.wut/addons/Panel/marker"))
	end)

	it("keeps fetched addons when the library pin moves, and drops unlisted ones", function()
		assert.equals(0, select(2, Fetch()))
		Write(consumer .. "/.wut/addons/Panel/marker", "kept")
		local output, code = Shell("cd " .. Quote(lib) .. " && touch NEW && git add NEW && " .. GIT
			.. " commit -q -m bump && git rev-parse HEAD")
		assert.equals(0, code, output)
		local bumped = output:match("(%x+)%s*exit=")
		Write(consumer .. "/.wut-version", bumped .. "\n")
		assert.equals(0, select(2, Fetch()))
		assert.equals(bumped .. "\n", Read(consumer .. "/.wut/.wut-ref"))
		assert.equals("kept", Read(consumer .. "/.wut/addons/Panel/marker"))

		Write(consumer .. "/wut.config.lua", 'return { specs = { "tests/spec" } }')
		assert.equals(0, select(2, Fetch()))
		assert.is_nil(Read(consumer .. "/.wut/addons/Panel/.wut-ref"))
	end)

	local function Leftovers()
		local output = Shell("cd " .. Quote(consumer) .. " && for left in .wut.new* .wut.lock; do if [ -e \"$left\" ]; then echo \"$left\"; fi; done")
		return output:gsub("exit=%d+%s*$", "")
	end

	it("lets cold fetches run at once and leaves one intact .wut", function()
		local runs = 4
		local output, code = Shell("cd " .. Quote(consumer) .. " && for i in $(seq " .. runs .. "); do (env -u WUT_DIR WUT_SOURCE="
			.. Quote(lib) .. " bash " .. script .. " >" .. Quote(scratch) .. "/out$i 2>" .. Quote(scratch)
			.. "/err$i; echo $? >" .. Quote(scratch) .. "/code$i) & done; wait")
		assert.equals(0, code, output)
		for i = 1, runs do
			local log = (Read(scratch .. "/err" .. i) or "")
			assert.equals("0\n", Read(scratch .. "/code" .. i), log)
			assert.equals(consumer .. "/.wut\n", Read(scratch .. "/out" .. i), log)
		end
		assert.equals(libSha .. "\n", Read(consumer .. "/.wut/.wut-ref"))
		assert.is_not_nil(Read(consumer .. "/.wut/wowtest/cli.lua"))
		assert.equals(addonSha .. "\n", Read(consumer .. "/.wut/addons/Panel/.wut-ref"))
		assert.is_not_nil(Read(consumer .. "/.wut/addons/Panel/Panel/Panel_Vanilla.toc"))
		assert.equals("", Leftovers())
	end)

	it("takes over a lock whose fetch died", function()
		os.execute("mkdir -p " .. Quote(consumer .. "/.wut.lock"))
		local output = Shell("sh -c 'echo $$'")
		Write(consumer .. "/.wut.lock/pid", output:match("^(%d+)") .. "\n")
		local _, code = Fetch()
		local stderr = Read(scratch .. "/stderr")
		assert.equals(0, code, stderr)
		assert.is_true(Has(stderr, "removing the stale lock"), stderr)
		assert.equals(libSha .. "\n", Read(consumer .. "/.wut/.wut-ref"))
		assert.equals("", Leftovers())
	end)

	it("gives up on a lock held by a live fetch", function()
		os.execute("mkdir -p " .. Quote(consumer .. "/.wut.lock"))
		local owner = Shell("sleep 30 >/dev/null 2>&1 & echo $!"):match("^(%d+)")
		Write(consumer .. "/.wut.lock/pid", owner .. "\n")
		local _, code = Fetch("WUT_LOCK_WAIT=1")
		os.execute("kill " .. owner)
		local stderr = Read(scratch .. "/stderr")
		assert.equals(1, code, stderr)
		assert.is_true(Has(stderr, "is still held after 1s"), stderr)
		assert.is_nil(Read(consumer .. "/.wut/.wut-ref"))
	end)

	it("uses WUT_DIR instead of downloading the library", function()
		Write(consumer .. "/.wut-version", ("0"):rep(40) .. "\n")
		local output, code = Fetch("WUT_DIR=" .. Quote(lib))
		assert.equals(0, code, output)
		assert.is_true(Has(output, lib .. "\n"), output)
		assert.is_nil(Read(consumer .. "/.wut/.wut-ref"))
		assert.equals(addonSha .. "\n", Read(consumer .. "/.wut/addons/Panel/.wut-ref"))
	end)

	it("needs no Lua when the repo has no wut.config.lua", function()
		os.remove(consumer .. "/wut.config.lua")
		local bin = scratch .. "/bin"
		os.execute("mkdir -p " .. Quote(bin))
		for _, name in ipairs({ "luajit", "lua5.1" }) do
			Write(bin .. "/" .. name, "#!/bin/sh\necho called >&2\nexit 99\n")
			os.execute("chmod +x " .. Quote(bin .. "/" .. name))
		end
		local output, code = Fetch("PATH=" .. Quote(bin) .. ":\"$PATH\"")
		local stderr = Read(scratch .. "/stderr")
		assert.equals(0, code, output .. stderr)
		assert.is_true(Has(stderr, "no wut.config.lua; skipping addons"), stderr)
		assert.is_false(Has(stderr, "called"), stderr)
		assert.equals(libSha .. "\n", Read(consumer .. "/.wut/.wut-ref"))
	end)

	local function ReleaseZip()
		local zip = scratch .. "/Panel.zip"
		local output, code = Shell("cd spec/fixtures/addons/Panel && zip -qrX " .. Quote(zip) .. " Panel && sha256sum "
			.. Quote(zip))
		assert.equals(0, code, output)
		return zip, output:match("^(%x+)")
	end

	local function PinRelease(zip, digest)
		Write(consumer .. "/wut.config.lua", string.format([[return {
	specs = { "tests/spec" },
	addons = { { name = "PanelZip", url = %q, sha256 = %q, toc = "Panel/Panel.toc" } },
}]], "file://" .. zip, digest))
	end

	it("fetches a release zip pinned by url and sha256, and wowmock loads it", function()
		local zip, digest = ReleaseZip()
		PinRelease(zip, digest)
		local output, code = Fetch()
		local stderr = Read(scratch .. "/stderr")
		assert.equals(0, code, output .. stderr)
		assert.equals(digest .. "\n", Read(consumer .. "/.wut/addons/PanelZip/.wut-ref"))
		assert.equals("Panel/Panel.toc\n", Read(consumer .. "/.wut/addons/PanelZip/.wut-toc"))
		assert.equals(0, select(2, Fetch()))
		assert.is_true(Has(Read(scratch .. "/stderr"), "addon PanelZip " .. digest .. " already in .wut/addons"))

		local Mock, Loader = require("wowmock"), require("wowmock.loader")
		local addonsDir = Loader.addonsDir
		Loader.addonsDir = consumer .. "/.wut/addons"
		Mock.Extend("Panel", { globals = { "PanelRegistry" } })
		Mock.Install()
		local ok, err = pcall(Loader.LoadAddon, "PanelZip")
		Loader.addonsDir = addonsDir
		Mock.ClearExtensions()
		assert.is_true(ok, err)
		assert.is_true(Mock.loadedAddons.Panel)
		assert.is_not_nil(PanelRegistry)
	end)

	it("rejects a release zip whose sha256 does not match", function()
		local zip = ReleaseZip()
		PinRelease(zip, ("0"):rep(64))
		local _, code = Fetch()
		assert.equals(1, code)
		assert.is_true(Has(Read(scratch .. "/stderr"), "does not match the pinned " .. ("0"):rep(64)))
		assert.is_nil(Read(consumer .. "/.wut/addons/PanelZip/.wut-ref"))
	end)

	it("rejects a .wut-version without a full SHA", function()
		Write(consumer .. "/.wut-version", "v0.1.0\n")
		local _, code = Fetch()
		assert.equals(1, code)
		assert.is_true(Has(Read(scratch .. "/stderr"), "must start with a full commit SHA"))
	end)
end)
