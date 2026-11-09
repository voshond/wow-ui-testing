local Raster = require("wowproof.raster")
local WowUiTextures = require("wowproof.sources.wow_ui_textures")
local WagoCasc = require("wowproof.sources.wago_casc")
local AtlasTable = require("wowproof.sources.atlas_table")
local RemoteDir = require("wowproof.sources.remote_dir")

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

	it("resolves client file IDs from the pinned build's cache only", function()
		assert.has_error(function() WagoCasc({ dir = dir }) end)
		Write(dir .. "/casc-1.2.3.4/7526019.png", "png")
		local resolve = WagoCasc({ build = "1.2.3.4", dir = dir, fetch = false })
		assert.equals(dir .. "/casc-1.2.3.4/7526019.png", resolve(7526019))
		assert.equals(dir .. "/casc-1.2.3.4/7526019.png", resolve("7526019"))
		assert.is_nil(resolve(1234))
		assert.is_nil(resolve(1.5))
		assert.is_nil(resolve("Interface\\Icons\\Spell_Holy_Renew"))
	end)

	it("copies files from a remote folder into its cache once, and stays inside it", function()
		Write(dir .. "/remote/classic/Male-Human.png", "png")
		local cache = dir .. "/cache"
		local resolve = RemoteDir({ remote = dir .. "/remote/", dir = cache })
		assert.equals(cache .. "/classic/Male-Human.png", resolve("classic/Male-Human.png"))
		assert.equals("png", Raster.Read(cache .. "/classic/Male-Human.png"))
		assert.is_nil(resolve("classic/Female-Orc.png"))
		Write(dir .. "/remote/classic/Female-Orc.png", "png")
		assert.is_nil(resolve("classic/Female-Orc.png"))
		assert.is_nil(resolve("../remote/classic/Female-Orc.png"))
		assert.is_nil(resolve("/etc/hostname"))
		assert.equals(cache .. "/classic/Male-Human.png", RemoteDir({ dir = cache })("classic/Male-Human.png"))
		assert.is_nil(RemoteDir({ dir = cache, remote = dir .. "/remote", fetch = false })("classic/Female-Orc.png"))
		assert.has_error(function() RemoteDir({ remote = dir }) end)
	end)

	it("looks atlases up by name, case-insensitively like the client", function()
		local info = { file = 7526019 }
		local resolve = AtlasTable({ ["RaidFrame-Icon-Rez"] = info })
		assert.equals(info, resolve("raidframe-icon-rez"))
		assert.equals(info, resolve("RAIDFRAME-ICON-REZ"))
		assert.is_nil(resolve("Missing"))
		assert.is_nil(resolve(nil))
	end)
end)
