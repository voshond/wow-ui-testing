local Layout = require("wowproof.layout")
local Paint = require("wowproof.paint")
local Scene = require("wowproof.scene")
local FakeScene = require("wowproof.spec.fake_scene")

describe("wowproof paint", function()
	local scene, frame

	before_each(function()
		scene = FakeScene.New()
		frame = scene.Node("Frame", scene.screen, {
			name = "Frame", width = 100, height = 20, points = { { point = "TOPLEFT", x = 10, y = -10 } },
		})
	end)

	local function Render(root, options)
		options = options or {}
		options.adapter, options.root = scene.adapter, root or frame
		options.layout = Layout.New(scene.adapter, { width = 400, height = 300 })
		options.pad = options.pad or 0
		return Paint.Render(options)
	end

	local function Has(svg, text)
		return svg:find(text, 1, true) ~= nil
	end

	local function Before(svg, first, second)
		return svg:find(first, 1, true) < svg:find(second, 1, true)
	end

	it("validates adapters", function()
		assert.has_error(function() Scene.Validate({ Parent = function() end }) end)
		assert.equals(scene.adapter, Scene.Validate(scene.adapter))
	end)

	it("crops to the region and draws colour textures", function()
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { color = { 1, 0, 0, 0.5 } } })
		local svg, info = Render()
		assert.equals(100, info.width)
		assert.equals(20, info.height)
		assert.is_true(Has(svg, 'viewBox="10 10 100 20"'))
		assert.is_true(Has(svg, '<rect x="10" y="10" width="100" height="20" fill="rgb(255,0,0)" fill-opacity="0.5"/>'))
	end)

	it("fills status bars from their value, honouring reverse and vertical fill", function()
		local bar = scene.Node("StatusBar", frame, {
			points = { { all = true } }, bar = { min = 0, max = 200, value = 50, color = { 0, 1, 0, 1 } },
		})
		assert.is_true(Has(Render(), 'x="10" y="10" width="25" height="20" fill="rgb(0,255,0)"'))
		bar.bar.reverse = true
		assert.is_true(Has(Render(), 'x="85" y="10" width="25" height="20"'))
		bar.bar.reverse, bar.bar.orientation = false, "VERTICAL"
		assert.is_true(Has(Render(), 'x="10" y="25" width="100" height="5"'))
	end)

	it("paints by strata, level, layer, sublevel, then creation order", function()
		local over = scene.Node("Texture", frame, { points = { { all = true } }, layer = "OVERLAY", texture = { color = { 0, 0, 1, 1 } } })
		local back = scene.Node("Texture", frame, { points = { { all = true } }, layer = "BACKGROUND", texture = { color = { 1, 0, 0, 1 } } })
		local child = scene.Node("Frame", frame, { points = { { all = true } }, level = 5 })
		scene.Node("Texture", child, { points = { { all = true } }, layer = "BACKGROUND", texture = { color = { 0, 1, 0, 1 } } })
		local svg = Render()
		assert.is_true(Before(svg, "rgb(255,0,0)", "rgb(0,0,255)"))
		assert.is_true(Before(svg, "rgb(0,0,255)", "rgb(0,255,0)"))
		child.strata, frame.strata = "LOW", "HIGH"
		svg = Render()
		assert.is_true(Before(svg, "rgb(0,255,0)", "rgb(255,0,0)"))
		assert.is_not_nil(over)
		assert.is_not_nil(back)
	end)

	it("skips hidden and transparent regions and multiplies alpha down the tree", function()
		local child = scene.Node("Frame", frame, { points = { { all = true } }, alpha = 0.5 })
		scene.Node("Texture", child, { points = { { all = true } }, texture = { color = { 1, 1, 1, 1 } }, alpha = 0.5 })
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { color = { 1, 0, 0, 1 } }, shown = false })
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { color = { 0, 0, 1, 1 } }, alpha = 0 })
		local svg = Render()
		assert.is_true(Has(svg, 'fill="rgb(255,255,255)" fill-opacity="0.25"'))
		assert.is_false(Has(svg, "rgb(255,0,0)"))
		assert.is_false(Has(svg, "rgb(0,0,255)"))
	end)

	it("refuses hidden or unplaced roots", function()
		frame.shown = false
		assert.has_error(function() Render() end)
		local loose = scene.Node("Frame", scene.screen, { width = 1, height = 1 })
		assert.has_error(function() Render(loose) end)
	end)

	it("draws text with justification, outline, colour codes and the font resolver", function()
		scene.Node("FontString", frame, {
			points = { { all = true } },
			text = { text = "HP |cffff0000low|r <ok>", size = 10, font = "Fonts\\X.ttf", flags = "OUTLINE", justifyH = "LEFT" },
		})
		local svg = Render(nil, { font = function(file) if file == "Fonts\\X.ttf" then return "Roboto", 700 end end })
		assert.is_true(Has(svg, 'x="10" y="20" font-family="Roboto" font-weight="700" font-size="10" text-anchor="start"'))
		assert.is_true(Has(svg, 'stroke="#000" stroke-width="1.2"'))
		assert.is_true(Has(svg, '<tspan fill="rgb(255,0,0)" fill-opacity="1">low</tspan>'))
		assert.is_true(Has(svg, "&lt;ok&gt;"))
	end)

	local function Image(file)
		if file == "Own\\Glow.tga" then return "data:image/png;base64,AA", 32, 32 end
	end

	it("embeds resolved images once, tints them, and marks unresolved files as placeholders", function()
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { file = "Own\\Glow.tga", vertexColor = { 1, 0.5, 0, 1 } } })
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { file = "Own\\Glow.tga" } })
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { file = "Interface\\Missing" } })
		local svg = Render(nil, { image = Image })
		local _, images = svg:gsub("base64,AA", "")
		assert.equals(1, images)
		assert.is_true(Has(svg, '<image id="d1" width="32" height="32" preserveAspectRatio="none" href="data:image/png;base64,AA"/>'))
		assert.is_true(Has(svg, 'values="1 0 0 0 0 0 0.5 0 0 0 0 0 0 0 0 0 0 0 1 0"'))
		assert.is_true(Has(svg, '<g opacity="1" filter="url(#d2)">'))
		assert.is_true(Has(svg, "<title>Interface\\Missing</title>"))
	end)

	it("crops images to their texture coordinates", function()
		scene.Node("Texture", frame, {
			points = { { all = true } }, texture = { file = "Own\\Glow.tga", texCoords = { 0.25, 0.5, 0, 0.25 } },
		})
		assert.is_true(Has(Render(nil, { image = Image }), 'viewBox="8 0 8 8"'))
		assert.same({ left = 0, top = 8, width = 32, height = 8 },
			Paint.SourceRect({ 0, 0.25, 0, 0.5, 1, 0.25, 1, 0.5 }, 32, 32))
		assert.same({ left = 0, top = 0, width = 32, height = 16 }, Paint.SourceRect(nil, 32, 16))
	end)

	it("draws atlases from their own sub-rectangle and maps later texture coordinates into it", function()
		local rect = { left = 0.5, right = 0.75, top = 0.25, bottom = 0.5 }
		local function Atlas(name)
			if name == "Known-Atlas" then return "data:image/png;base64,AT", 16, 8, rect end
		end
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { atlas = "Known-Atlas" } })
		scene.Node("Texture", frame, {
			points = { { all = true } }, texture = { atlas = "Known-Atlas", texCoords = { 0.625, 0.75, 0.25, 0.5 } },
		})
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { atlas = "Missing-Atlas" } })
		local svg = Render(nil, { atlas = Atlas })
		local _, images = svg:gsub("base64,AT", "")
		assert.equals(1, images)
		assert.is_true(Has(svg, '<image id="d1" width="16" height="8" preserveAspectRatio="none" href="data:image/png;base64,AT"/>'))
		assert.is_true(Has(svg, 'viewBox="0 0 16 8"'))
		assert.is_true(Has(svg, 'viewBox="8 0 8 8"'))
		assert.is_true(Has(svg, "<title>Missing-Atlas</title>"))
		assert.same({ 1, 0, 0, 1 }, Paint.AtlasCoords({ 0.75, 0.5, 0.25, 0.5 }, rect))
		assert.same({ 0, 1, 1, 1, 0, 0, 1, 0 }, Paint.AtlasCoords({ 0.5, 0.5, 0.75, 0.5, 0.5, 0.25, 0.75, 0.25 }, rect))
		assert.is_nil(Paint.AtlasCoords(nil, rect))
	end)

	it("maps rotated and tiled texture coordinates through a pattern transform", function()
		local coords = { 0, 2, 1, 2, 0, 0, 1, 0 }
		assert.is_true(Paint.NeedsAffine(coords))
		assert.is_false(Paint.NeedsAffine({ 0.1, 0.9, 0.1, 0.9 }))
		assert.is_true(Paint.NeedsAffine({ 1, 0, 0, 1 }))
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { file = "Own\\Glow.tga", texCoords = coords } })
		local svg = Render(nil, { image = Image })
		assert.is_true(Has(svg, 'patternTransform="matrix(0 0.625 -1.5625 0 110 10)"'))
		assert.is_true(Has(svg, '<rect x="10" y="10" width="100" height="20" fill="url(#d2)"/>'))
	end)

	it("skips texture coordinates that collapse the image", function()
		assert.is_nil(Paint.AffineTransform({ left = 0, top = 0, width = 10, height = 10 }, { 0, 0, 0, 0, 0, 0, 0, 0 }, 16, 16))
		assert.is_nil(Paint.AffineTransform({ left = 0, top = 0, width = 200, height = 10 }, { 0, 0, 0, 0.0001, 1, 0, 1, 0.0001 }, 16, 16))
	end)

	it("paints Blizzard's white texture as a tinted solid", function()
		scene.Node("Texture", frame, {
			points = { { all = true } }, texture = { file = "Interface\\Buttons\\WHITE8X8", vertexColor = { 0, 0, 1, 0.5 } },
		})
		assert.is_true(Has(Render(), 'fill="rgb(0,0,255)" fill-opacity="0.5"'))
	end)

	it("draws nine-slice textures with fixed corners", function()
		scene.Node("Texture", frame, { points = { { all = true } }, texture = { file = "Own\\Glow.tga", slice = { 8, 8, 8, 8 } } })
		local svg = Render(nil, { image = Image })
		local _, pieces = svg:gsub('<use href="#d1"/>', "")
		assert.equals(9, pieces)
		assert.is_true(Has(svg, '<svg x="10" y="10" width="8" height="8" viewBox="0 0 8 8"'))
		assert.is_true(Has(svg, '<svg x="18" y="18" width="84" height="4" viewBox="8 8 16 16"'))
		assert.is_true(Has(svg, '<svg x="102" y="22" width="8" height="8" viewBox="24 24 8 8"'))
	end)

	it("clips children of clipping frames and keeps clipped-away content out of the crop", function()
		scene.adapter.ClipsChildren = function(node) return node.clips == true end
		local clip = scene.Node("Frame", frame, { points = { { all = true } }, clips = true })
		scene.Node("Texture", clip, {
			width = 5000, height = 20, points = { { point = "RIGHT", relativePoint = "RIGHT", x = 50 } },
			texture = { color = { 1, 0, 0, 1 } },
		})
		scene.Node("Texture", clip, {
			width = 10, height = 10, points = { { point = "LEFT", relativePoint = "RIGHT", x = 100 } },
			texture = { color = { 0, 0, 1, 1 } },
		})
		local svg, info = Render()
		assert.equals(100, info.width)
		assert.is_true(Has(svg, '<clipPath id="d1"><rect x="10" y="10" width="100" height="20"/></clipPath>'))
		assert.is_true(Has(svg, '<g clip-path="url(#d1)">\n<rect x="-4840"'))
		assert.is_false(Has(svg, "rgb(0,0,255)"))
	end)

	it("places status bar fill textures from the bar's value", function()
		scene.adapter.FillOf = function(node) return node.fillOf end
		local bar = scene.Node("StatusBar", frame, { points = { { all = true } }, bar = { min = 0, max = 4, value = 1 } })
		local fill = scene.Node("Texture", bar, { texture = { color = { 0, 1, 0, 1 } } })
		fill.fillOf = bar
		scene.Node("Texture", bar, {
			width = 4, height = 4, points = { { point = "LEFT", relativeTo = fill, relativePoint = "RIGHT" } },
			texture = { color = { 1, 0, 0, 1 } },
		})
		local svg = Render()
		assert.is_true(Has(svg, '<rect x="10" y="10" width="25" height="20" fill="rgb(0,255,0)"'))
		assert.is_true(Has(svg, '<rect x="35" y="18" width="4" height="4" fill="rgb(255,0,0)"'))
	end)

	it("draws models through the model hook, cropped to cover, with model alpha and desaturation", function()
		scene.adapter.Model = function(node) return node.model end
		local model = scene.Node("PlayerModel", frame, {
			points = { { all = true } }, alpha = 0.5, model = { unit = "target", zoom = 1, modelAlpha = 0.5, desaturation = 0.25 },
		})
		local asked
		local function Portrait(info)
			asked = info
			return { file = "Own\\Glow.tga", texCoords = { 0, 1, 0, 0.5 } }
		end
		local svg = Render(nil, { image = Image, model = Portrait })
		assert.equals(model.model, asked)
		assert.is_true(Has(svg, 'href="data:image/png;base64,AA"'))
		assert.is_true(Has(svg, '<feColorMatrix type="saturate" values="0.75"/>'))
		assert.is_true(Has(svg, '<g opacity="0.25" filter="url(#d2)">'))
		assert.is_true(Has(svg, 'viewBox="0 4.8 32 6.4"'))
		assert.same({ left = 0, top = 12, width = 32, height = 8 },
			Paint.CoverRect({ left = 0, top = 0, width = 32, height = 32 }, { left = 0, top = 0, width = 100, height = 25 }))
	end)

	it("draws model art from a local file as is", function()
		scene.adapter.Model = function(node) return node.model end
		scene.Node("PlayerModel", frame, { points = { { all = true } }, model = { unit = "player" } })
		local function File(path)
			if path == "captures/Male-Human.png" then return "data:image/png;base64,CA", 20, 20 end
		end
		local svg = Render(nil, { image = Image, file = File, model = function() return { path = "captures/Male-Human.png" } end })
		assert.is_true(Has(svg, 'href="data:image/png;base64,CA"'))
		svg = Render(nil, { image = Image, model = function() return { path = "captures/Missing.png" } end })
		assert.is_true(Has(svg, "<title>model: player</title>"))
	end)

	it("draws models without art as placeholders titled with their unit, and cleared models as nothing", function()
		scene.adapter.Model = function(node) return node.model end
		local model = scene.Node("PlayerModel", frame, { points = { { all = true } }, model = { unit = "focus" } })
		local svg = Render(nil, { image = Image, model = function() return "Interface\\Missing" end })
		assert.is_true(Has(svg, "<title>model: focus</title>"))
		assert.is_true(Has(Render(), "<title>model: focus</title>"))
		model.model = { displayId = 42 }
		assert.is_true(Has(Render(), "<title>model: display 42</title>"))
		model.model = { modelAlpha = 1 }
		assert.is_false(Has(Render(), "<title>"))
		model.model = { unit = "focus", modelAlpha = 0 }
		assert.is_false(Has(Render(), "<title>"))
		scene.adapter.Model = nil
		assert.is_true(Has(Render(), "<title>model: PlayerModel</title>"))
	end)

	it("renders the same scene to the same SVG", function()
		scene.Node("StatusBar", frame, { points = { { all = true } }, bar = { min = 0, max = 3, value = 1 } })
		scene.Node("FontString", frame, { points = { { point = "CENTER" } }, text = { text = "1/3" } })
		assert.equals(Render(), Render())
	end)
end)
