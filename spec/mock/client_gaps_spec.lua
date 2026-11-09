local Helpers = require("spec.mock.helpers")
local Mock = Helpers.Mock

--[[
Generic client behaviour Socialite (Ace3, Titan Panel) needed and first
worked around in its own mock. The XML comment gap is in loader_spec.
]]
describe("wowmock client gaps", function()
	before_each(function()
		Mock.ClearExtensions()
		Mock.Install()
		Mock.InstallUI()
	end)

	it("answers IsObjectType for the whole widget hierarchy", function()
		local frame = CreateFrame("Frame", nil, UIParent)
		local button = CreateFrame("Button", nil, UIParent)
		local texture = frame:CreateTexture()
		for _, t in ipairs({ "Frame", "Region", "ScriptRegion", "Object" }) do
			assert.is_true(frame:IsObjectType(t), "Frame is a " .. t)
			assert.is_true(button:IsObjectType(t), "Button is a " .. t)
		end
		assert.is_true(button:IsObjectType("Button"))
		for _, t in ipairs({ "Texture", "TextureBase", "Region", "ScriptRegion", "Object" }) do
			assert.is_true(texture:IsObjectType(t), "Texture is a " .. t)
		end
		assert.is_false(frame:IsObjectType("Button"))
		assert.is_false(texture:IsObjectType("Frame"))
		assert.is_true(frame:CreateAnimationGroup():IsObjectType("Object"))
	end)

	it("returns nil for unknown lowercase fields", function()
		local frame = CreateFrame("Frame", nil, UIParent)
		assert.is_nil(frame.anchor)
		assert.same({}, frame.anchor or {})
		frame.anchor = "TOP"
		assert.equals("TOP", frame.anchor)
		assert.equals("function", type(frame.SetClampedToScreen))
	end)

	it("keeps button texture slots", function()
		local button = CreateFrame("Button", nil, UIParent)
		for _, slot in ipairs({ "Normal", "Pushed", "Highlight", "Disabled" }) do
			assert.is_nil(button["Get" .. slot .. "Texture"](button))
			button["Set" .. slot .. "Texture"](button, "Interface\\Buttons\\" .. slot)
			local texture = button["Get" .. slot .. "Texture"](button)
			assert.is_true(texture:IsObjectType("Texture"))
			assert.equals("Interface\\Buttons\\" .. slot, texture:GetTexture())
			assert.equals(button, texture:GetParent())
			button["Set" .. slot .. "Texture"](button, "Interface\\Buttons\\Other")
			assert.equals(texture, button["Get" .. slot .. "Texture"](button))
			button["Clear" .. slot .. "Texture"](button)
			assert.is_nil(button["Get" .. slot .. "Texture"](button))
		end
		local own = button:CreateTexture()
		button:SetHighlightTexture(own)
		assert.equals(own, button:GetHighlightTexture())
		local frame = CreateFrame("Frame", nil, UIParent)
		assert.has_error(function() frame:SetNormalTexture("x") end)
	end)

	it("provides the client's Lua aliases and string helpers", function()
		assert.equals("07", format("%02d", 7))
		assert.equals(2, floor(2.7))
		local list = { 1, 2, 3 }
		assert.equals(3, tremove(list))
		assert.equals("bc", strsub("abc", 2))
		assert.equals("ABC", strupper("abc"))
		assert.same({ "a", "b", "c" }, { strsplit(",", "a,b,c") })
		assert.same({ "a", "b", "c d" }, { strsplit(" ,", "a b,c d", 3) })
		assert.same({ "a", "", "b" }, { strsplit("-", "a--b") })
		assert.equals("a, b, c", strjoin(", ", "a", "b", "c"))
		assert.equals("ab1", strconcat("a", "b", 1))
		assert.same({ "1", "nil", "true" }, { tostringall(1, nil, true) })
	end)

	it("hooks functions after the original with hooksecurefunc", function()
		local calls = {}
		_G.GapsProbe = function(value) calls[#calls + 1] = "original " .. value; return value * 2, nil, "x" end
		hooksecurefunc("GapsProbe", function(value) calls[#calls + 1] = "hook " .. value end)
		assert.same({ 6, nil, "x" }, { GapsProbe(3) })
		assert.same({ "original 3", "hook 3" }, calls)
		_G.GapsProbe = nil

		local frame = CreateFrame("Frame", nil, UIParent)
		local hooked
		hooksecurefunc(frame, "Show", function(self) hooked = self end)
		frame:Show()
		assert.equals(frame, hooked)
		assert.is_true(frame:IsShown())
	end)

	it("calls through securecall and records PlaySound and the cursor", function()
		assert.equals(3, securecall(function(a, b) return a + b end, 1, 2))
		assert.equals("enUS", securecall("GetLocale"))
		assert.is_true(PlaySound(856, "Master"))
		assert.same({ { 856, "Master" } }, Mock.sounds)
		assert.same({ 0, 0 }, { GetCursorPosition() })
		Mock.cursor = { x = 10, y = 20 }
		assert.same({ 10, 20 }, { GetCursorPosition() })
	end)

	it("defines the default fonts, font colours and WorldFrame", function()
		for _, name in ipairs({ "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontHighlight",
			"GameFontHighlightSmall", "GameFontHighlightLarge", "GameFontDisable", "GameFontDisableSmall" }) do
			assert.is_true(_G[name]:IsObjectType("Font"), name)
			assert.is_not_nil(_G[name]:GetFont(), name)
		end
		assert.same({ 1, 0.82, 0 }, { NORMAL_FONT_COLOR:GetRGB() })
		assert.same({ 1, 1, 1 }, { HIGHLIGHT_FONT_COLOR:GetRGB() })
		assert.equals("|cffffd100Hi|r", NORMAL_FONT_COLOR_CODE .. "Hi" .. FONT_COLOR_CODE_CLOSE)
		assert.equals("|cffffd100Hi|r", NORMAL_FONT_COLOR:WrapTextInColorCode("Hi"))
		assert.equals("|cffffffff", HIGHLIGHT_FONT_COLOR_CODE)
		assert.is_true(WorldFrame:IsObjectType("Frame"))
	end)
end)
