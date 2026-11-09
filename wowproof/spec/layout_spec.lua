local Layout = require("wowproof.layout")
local FakeScene = require("wowproof.spec.fake_scene")

describe("wowproof layout", function()
	local scene, layout

	before_each(function()
		scene = FakeScene.New()
		layout = Layout.New(scene.adapter, { width = 1000, height = 500 })
	end)

	local function Rect(node)
		local rect = layout:Rect(node)
		return { rect.left, rect.top, rect.width, rect.height }
	end

	it("fills the screen with a parentless region without points", function()
		assert.same({ 0, 0, 1000, 500 }, Rect(scene.screen))
	end)

	it("places a single point with its size, y offsets going up", function()
		local frame = scene.Node("Frame", scene.screen, {
			width = 200, height = 40,
			points = { { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 10, y = -20 } },
		})
		assert.same({ 10, 20, 200, 40 }, Rect(frame))
	end)

	it("centers on the relative region's anchor", function()
		local frame = scene.Node("Frame", scene.screen, {
			width = 100, height = 50, points = { { point = "CENTER", x = 0, y = 50 } },
		})
		assert.same({ 450, 175, 100, 50 }, Rect(frame))
	end)

	it("stretches an axis between two points", function()
		local frame = scene.Node("Frame", scene.screen, {
			width = 300, height = 60, points = { { point = "CENTER" } },
		})
		local bar = scene.Node("StatusBar", frame, {
			height = 20,
			points = {
				{ point = "TOPLEFT", x = 5, y = -5 },
				{ point = "TOPRIGHT", x = -5, y = -5 },
			},
		})
		assert.same({ 355, 225, 290, 20 }, Rect(bar))
	end)

	it("copies the relative rect for SetAllPoints", function()
		local frame = scene.Node("Frame", scene.screen, { width = 80, height = 30, points = { { point = "TOPLEFT" } } })
		local texture = scene.Node("Texture", frame, { points = { { all = true } } })
		assert.same({ 0, 0, 80, 30 }, Rect(texture))
	end)

	it("anchors to another region than the parent", function()
		local a = scene.Node("Frame", scene.screen, { width = 100, height = 20, points = { { point = "TOPLEFT" } } })
		local b = scene.Node("Frame", scene.screen, {
			width = 50, height = 20,
			points = { { point = "TOPLEFT", relativeTo = a, relativePoint = "BOTTOMLEFT", x = 0, y = -4 } },
		})
		assert.same({ 0, 24, 50, 20 }, Rect(b))
	end)

	it("applies the effective scale to size and offsets", function()
		local frame = scene.Node("Frame", scene.screen, {
			scale = 2, width = 100, height = 10, points = { { point = "TOPLEFT", x = 10, y = -10 } },
		})
		local child = scene.Node("Frame", frame, { width = 10, height = 10, points = { { point = "TOPLEFT", x = 5 } } })
		assert.same({ 20, 20, 200, 20 }, Rect(frame))
		assert.same({ 30, 20, 20, 20 }, Rect(child))
	end)

	it("leaves a parented region without points unresolved, and survives cycles", function()
		local loose = scene.Node("Frame", scene.screen, { width = 10, height = 10 })
		assert.is_nil(layout:Rect(loose))
		local a = scene.Node("Frame", scene.screen, { width = 10, height = 10 })
		local b = scene.Node("Frame", scene.screen, { width = 10, height = 10, points = { { point = "LEFT", relativeTo = a } } })
		a.points = { { point = "LEFT", relativeTo = b } }
		assert.is_nil(layout:Rect(a))
	end)

	it("sizes a font string from its text when it has no size", function()
		local text = scene.Node("FontString", scene.screen, {
			points = { { point = "TOPLEFT" } }, text = { text = "abcd", size = 10 },
		})
		assert.same({ 0, 0, 22, 10 }, Rect(text))
	end)

	it("rejects unknown anchor points", function()
		local frame = scene.Node("Frame", scene.screen, { width = 1, height = 1, points = { { point = "MIDDLE" } } })
		assert.has_error(function() layout:Rect(frame) end)
	end)
end)
