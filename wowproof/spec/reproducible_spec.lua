local Proof = require("wowproof")
local Raster = require("wowproof.raster")
local FakeScene = require("wowproof.spec.fake_scene")

local function Render(source, dir)
	local scene = FakeScene.New()
	local frame = scene.Node("Frame", scene.screen, { width = 16, height = 8, points = { { point = "CENTER" } } })
	scene.Node("Texture", frame, { width = 8, height = 8, points = { { point = "LEFT" } },
		texture = { file = "Interface\\Source" } })
	scene.Node("Texture", frame, { width = 8, height = 8, points = { { point = "RIGHT" } },
		texture = { atlas = "half" } })
	local proof = Proof.New({ adapter = scene.adapter, outDir = dir, title = "Reproducible", assets = {
		textures = function() return source end,
		atlases = function(name)
			if name == "half" then return { file = "Interface\\Source", left = 0, right = 0.5, top = 0, bottom = 1 } end
		end,
	} })
	local entry = proof:Snapshot(frame, "scene")
	local pngs = {}
	for _, png in ipairs({ entry.png, Raster.RawToPng(("\255\0\0\255"):rep(4), 2, 2, dir .. "/raw.png") }) do
		pngs[#pngs + 1] = Raster.Read(png)
	end
	return Raster.Read(entry.svg), pngs
end

describe("wowproof reproducibility", function()
	it("renders the same scene to byte-identical SVG and PNG output", function()
		if not (Raster.ImageTool() and Raster.Has("rsvg-convert")) then return end
		local scratch = io.popen("mktemp -d"):read("*l")
		local source = scratch .. "/source.tga"
		assert.is_true(Raster.Run(Raster.ImageTool() .. " -size 8x8 xc:red " .. Raster.Quote(source) .. " >/dev/null 2>&1"))

		local firstSvg, firstPngs = Render(source, scratch .. "/first")
		-- ImageMagick timestamps have second resolution.
		os.execute("sleep 1.1")
		local secondSvg, secondPngs = Render(source, scratch .. "/second")
		local cached = {}
		for line in io.popen("ls " .. Raster.Quote(scratch .. "/first/.cache") .. "/*.png"):lines() do
			cached[#cached + 1] = Raster.Read(line)
		end
		os.execute("rm -rf " .. Raster.Quote(scratch))

		assert.is_not_nil(firstSvg:find("data:image/png;base64,", 1, true), "the scene inlines rasterised images")
		assert.is_true(firstSvg == secondSvg, "SVG differs between runs")
		assert.equals(#firstPngs, #secondPngs)
		for i = 1, #firstPngs do
			assert.is_true(firstPngs[i] == secondPngs[i], "PNG " .. i .. " differs between runs")
		end
		assert.equals(2, #cached)
		for _, png in ipairs(cached) do
			assert.is_nil(png:find("tIME", 1, true), "inlined PNG carries a tIME chunk")
			assert.is_nil(png:find("date:", 1, true), "inlined PNG carries date text chunks")
		end
	end)
end)
