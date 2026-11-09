local Config = require("wowtest.config")

describe("wowtest config", function()
	it("normalizes spec dirs, prefixes and defaults", function()
		local config = Config.Normalize({ specs = { "tests/spec", { dir = "lib/spec/", prefix = "lib" } } })
		assert.same({ { dir = "tests/spec/", prefix = "" }, { dir = "lib/spec/", prefix = "lib/" } }, config.specs)
		assert.equals("*_spec.lua", config.pattern)
		assert.same({}, config.path)
		assert.same({ include = {}, exclude = {} }, config.syntax)
	end)

	it("accepts a single string for path and syntax lists", function()
		local config = Config.Normalize({ specs = "s", path = "./x/?.lua", syntax = { include = "Addon" } })
		assert.same({ "./x/?.lua" }, config.path)
		assert.same({ "Addon" }, config.syntax.include)
	end)

	it("rejects configs without spec dirs", function()
		assert.has_error(function() Config.Normalize({}) end)
		assert.has_error(function() Config.Normalize({ specs = { { prefix = "x" } } }) end)
		assert.has_error(function() Config.Normalize("nope") end)
	end)

	it("maps spec keys to files and back through prefixes", function()
		local config = Config.Normalize({ specs = { "tests/spec", { dir = "lib/spec", prefix = "lib" } } })
		assert.equals("tests/spec/units/a_spec.lua", Config.SpecPath(config, "units/a_spec.lua"))
		assert.equals("lib/spec/b_spec.lua", Config.SpecPath(config, "lib/b_spec.lua"))
		assert.equals("lib/b_spec.lua", Config.SpecKey(config.specs[2], "lib/spec/b_spec.lua"))
	end)

	it("finds the default config file or the explicit one", function()
		local seen = {}
		local function Exists(file) seen[#seen + 1] = file return file == "tests/wut.config.lua" end
		assert.equals("tests/wut.config.lua", Config.Find(nil, Exists))
		assert.same(Config.DEFAULT_FILES, seen)
		assert.equals("mine.lua", Config.Find("mine.lua", Exists))
		assert.has_error(function() Config.Find(nil, function() return false end) end)
	end)

	it("builds the syntax check command from include and exclude", function()
		assert.is_nil(Config.SyntaxCommand(Config.Normalize({ specs = "s" })))
		local config = Config.Normalize({ specs = "s", syntax = { include = { "A", "B" }, exclude = "*/Libs/*" } })
		assert.equals("find 'A' 'B' -name '*.lua' -not -path '*/Libs/*'", Config.SyntaxCommand(config))
	end)

	it("validates third-party addons", function()
		local sha = ("a"):rep(40)
		local config = Config.Normalize({ specs = "s", addons = {
			{ name = "Titan", source = "owner/Titan.Panel", ref = sha, toc = "Titan/Titan.toc" },
			{ name = "Local", source = "/tmp/repo", ref = sha },
		} })
		assert.same({ name = "Titan", source = "owner/Titan.Panel", ref = sha, toc = "Titan/Titan.toc" }, config.addons[1])
		assert.same({}, Config.Normalize({ specs = "s" }).addons)
		local function Bad(entry) return function() Config.Normalize({ specs = "s", addons = { entry } }) end end
		assert.has_error(Bad({ name = "a/b", source = "o/r", ref = sha }))
		assert.has_error(Bad({ name = "A", source = "nope", ref = sha }))
		assert.has_error(Bad({ name = "A", source = "o/r", ref = "main" }))
		assert.has_error(Bad({ name = "A", source = "o/r", ref = sha, toc = "../x.toc" }))
		assert.has_error(function()
			Config.Normalize({ specs = "s", addons = { { name = "A", source = "o/r", ref = sha }, { name = "A", source = "o/r", ref = sha } } })
		end)
	end)

	it("loads the fixture config from disk", function()
		local config = Config.Load("spec/fixtures/runner/wut.config.lua")
		assert.equals("*_check.lua", config.pattern)
		assert.equals("pkg/", config.specs[2].prefix)
	end)
end)
