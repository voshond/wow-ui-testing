local Proof = require("wowproof")
local Raster = require("wowproof.raster")
local MockState = require("wowproof.adapters.mock_state")
local FakeScene = require("wowproof.spec.fake_scene")

local FORBIDDEN = { "Unit" .. "Frames", "%f[%w_]ns" .. "%.", "tests" .. "/" }

local function PackageFiles()
	local files = {}
	local handle = io.popen("find wowproof -type f")
	for file in handle:lines() do files[#files + 1] = file end
	handle:close()
	return files
end

describe("wowproof package", function()
	it("knows nothing about the addon that uses it", function()
		for _, file in ipairs(PackageFiles()) do
			local content = Raster.Read(file)
			for _, pattern in ipairs(FORBIDDEN) do
				assert.is_nil(content:find(pattern), file .. " mentions " .. pattern)
			end
		end
	end)

	it("base64-encodes like the standard alphabet", function()
		assert.equals("", Raster.Base64(""))
		assert.equals("TQ==", Raster.Base64("M"))
		assert.equals("TWE=", Raster.Base64("Ma"))
		assert.equals("TWFu", Raster.Base64("Man"))
	end)

	it("writes snapshots and a contact sheet", function()
		local dir = io.popen("mktemp -d"):read("*l")
		local scene = FakeScene.New()
		local frame = scene.Node("Frame", scene.screen, { width = 20, height = 10, points = { { point = "CENTER" } } })
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { color = { 1, 1, 1, 1 } } })
		local proof = Proof.New({ adapter = scene.adapter, outDir = dir, png = false, title = "Fake" })
		local entry = proof:Snapshot(frame, "white box")
		proof:Fail("broken", "boom <here>")
		local sheet = Raster.Read(proof:Sheet())
		assert.equals(dir .. "/white-box.svg", entry.svg)
		assert.is_true(Raster.Exists(entry.svg))
		assert.is_not_nil(sheet:find("1 snapshots, 1 failed", 1, true))
		assert.is_not_nil(sheet:find("boom &lt;here&gt;", 1, true))
		os.execute("rm -rf " .. Raster.Quote(dir))
	end)

	it("reads the __state widget model through the mock_state adapter", function()
		local secret = {}
		local function Secret(value) return setmetatable({ value = value }, secret) end
		local function Object(kind, parent, state)
			state.parent, state.kids, state.points = parent, {}, state.points or {}
			local object = { __type = kind, __state = state, __calls = {} }
			if parent then parent.__state.kids[object] = true end
			return object
		end
		local root = Object("Frame", nil, {})
		local bar = Object("StatusBar", root, { min = 0, max = Secret(10), value = Secret(4), shown = true })
		bar.__state.fill = Object("Texture", bar, { vertexColor = { 1, 0, 0, 1 } })
		local text = Object("FontString", bar, { text = Secret("40%"), fontObject = "Font" })
		text.__calls[1] = { "SetJustifyH", "RIGHT" }
		local font = Object("Font", nil, { font = { "F.ttf", 11, "OUTLINE" } })
		local registry = { root, bar, bar.__state.fill, text, font }
		local adapter = MockState({
			isSecret = function(value) return getmetatable(value) == secret end,
			reveal = function(value) return value.value end,
			objects = function() return registry end,
			globals = { Font = font },
		})
		bar.__calls[1] = { "SetClipsChildren", true }
		assert.same({ bar.__state.fill, text }, adapter.Children(bar))
		assert.equals(bar, adapter.FillOf(bar.__state.fill))
		assert.is_nil(adapter.FillOf(text))
		assert.is_true(adapter.ClipsChildren(bar))
		assert.is_false(adapter.ClipsChildren(root))
		assert.same({ min = 0, max = 10, value = 4, reverse = false, color = { 1, 0, 0, 1 } }, adapter.Bar(bar))
		local info = adapter.Text(text)
		assert.equals("40%", info.text)
		assert.equals(11, info.size)
		assert.equals("RIGHT", info.justifyH)
		assert.equals(4, adapter.Order(text))
	end)
end)
