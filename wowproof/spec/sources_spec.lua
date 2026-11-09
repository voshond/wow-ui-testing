local Raster = require("wowproof.raster")
local WowUiTextures = require("wowproof.sources.wow_ui_textures")

local REF = "abc123"

describe("wowproof wow-ui-textures source", function()
	local dir

	local function Write(path, content)
		Raster.MakeDir(path:match("^(.*)/[^/]+$"))
		Raster.Write(path, content)
	end

	before_each(function()
		dir = io.popen("mktemp -d"):read("*l")
		Write(dir .. "/trees/" .. REF .. ".tsv", "tree\ticons-sha\tICONS\nblob\tx\tREADME.md\n")
		Write(dir .. "/trees/icons-sha.tsv", "blob\ta\tSpell_Holy_Renew.PNG\n")
		Write(dir .. "/" .. REF .. "/ICONS/SPELL_HOLY_RENEW.png", "png")
	end)

	after_each(function()
		os.execute("rm -rf " .. Raster.Quote(dir))
	end)

	it("needs a pinned ref", function()
		assert.has_error(function() WowUiTextures({ dir = dir }) end)
	end)

	it("resolves Interface paths case-insensitively from its cache, with or without extensions", function()
		local resolve = WowUiTextures({ ref = REF, dir = dir, fetch = false })
		local cached = dir .. "/" .. REF .. "/ICONS/SPELL_HOLY_RENEW.png"
		assert.equals(cached, resolve("Interface\\Icons\\Spell_Holy_Renew"))
		assert.equals(cached, resolve("interface/icons/spell_holy_renew.blp"))
		assert.is_nil(resolve("MyAddon\\Media\\Glow"))
		assert.is_nil(resolve(1234))
	end)

	it("remembers art the pinned commit doesn't have, without asking the network again", function()
		local resolve = WowUiTextures({ ref = REF, dir = dir })
		assert.is_nil(resolve("Interface\\Icons\\Spell_Nature_LifeBloom"))
		assert.is_nil(resolve("Interface\\Nowhere\\Thing"))
		local missing = Raster.Read(dir .. "/missing-" .. REF .. ".txt")
		assert.equals("ICONS\\SPELL_NATURE_LIFEBLOOM\nNOWHERE\\THING\n", missing)
	end)
end)
