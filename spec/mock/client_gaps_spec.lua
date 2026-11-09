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
		assert.same({ 1, 210 / 255, 0 }, { NORMAL_FONT_COLOR:GetRGB() })
		assert.same({ 1, 1, 1 }, { HIGHLIGHT_FONT_COLOR:GetRGB() })
		assert.equals("|cffffd200Hi|r", NORMAL_FONT_COLOR_CODE .. "Hi" .. FONT_COLOR_CODE_CLOSE)
		assert.equals("|cffffd200Hi|r", NORMAL_FONT_COLOR:WrapTextInColorCode("Hi"))
		assert.equals("|cffffffff", HIGHLIGHT_FONT_COLOR_CODE)
		assert.is_true(WorldFrame:IsObjectType("Frame"))
	end)
end)

describe("wowmock gaps from loading Titan Panel", function()
	before_each(function()
		Mock.ClearExtensions()
		Mock.Install()
	end)

	it("derives screen geometry from the anchors", function()
		local frame = CreateFrame("Frame", nil, UIParent)
		assert.is_nil(frame:GetLeft())
		frame:SetSize(100, 40)
		frame:SetPoint("CENTER", UIParent, "CENTER", 10, 0)
		assert.same({ 920, 520, 100, 40 }, { frame:GetRect() })
		assert.equals(920, frame:GetLeft())
		assert.equals(1020, frame:GetRight())
		assert.equals(520, frame:GetBottom())
		assert.equals(560, frame:GetTop())
		assert.same({ 970, 540 }, { frame:GetCenter() })

		local child = CreateFrame("Frame", nil, frame)
		child:SetScale(2)
		child:SetSize(10, 10)
		child:SetPoint("BOTTOMLEFT")
		assert.same({ 460, 260, 10, 10 }, { child:GetRect() })

		UIParent:SetSize(1000, 500)
		assert.same({ 510, 250 }, { frame:GetCenter() })
		assert.equals(1000, GetScreenWidth())
	end)

	it("anchors to a region by its global name", function()
		local frame = CreateFrame("Frame", "GapsNamedAnchor", UIParent)
		local other = CreateFrame("Frame", nil, UIParent)
		other:SetPoint("TOP", "GapsNamedAnchor", "BOTTOM")
		assert.equals(frame, select(2, other:GetPoint(1)))
		other:SetAllPoints("GapsNamedAnchor")
		assert.equals(frame, select(2, other:GetPoint(1)))
		assert.has_error(function() other:SetPoint("TOP", "GapsMissingRegion") end)
		_G.GapsNamedAnchor = nil
	end)

	it("answers HasScript for handlers", function()
		local frame = CreateFrame("Button", nil, UIParent)
		assert.is_true(frame:HasScript("OnClick"))
		assert.is_true(frame:HasScript("OnEnter"))
		assert.is_false(frame:HasScript("Click"))
	end)

	it("provides a bit library where the Lua has none", function()
		local native = _G.bit
		_G.bit = nil
		Mock.Install()
		local installed = _G.bit
		_G.bit = native
		assert.equals(Mock.BIT, installed)
		assert.equals(8, installed.band(12, 10))
		assert.equals(14, installed.bor(12, 10))
		assert.equals(6, installed.bxor(12, 10))
		assert.equals(16, installed.lshift(1, 4))
		assert.equals(1, installed.rshift(16, 4))
		assert.equals(2 ^ 32 - 1, installed.bnot(0))
		Mock.Install()
		assert.equals(native, _G.bit)
	end)

	it("defines the client globals addons read", function()
		assert.equals("|cff20ff20", GREEN_FONT_COLOR_CODE)
		assert.equals("|cffff2020", RED_FONT_COLOR_CODE)
		assert.equals("|cff808080", GRAY_FONT_COLOR_CODE)
		assert.equals("|cffffff9a", LIGHTYELLOW_FONT_COLOR_CODE)
		assert.same({ 0.5, 0.5, 0.5 }, { (function(r, g, b) return math.floor(r * 10 + 0.5) / 10,
			math.floor(g * 10 + 0.5) / 10, math.floor(b * 10 + 0.5) / 10 end)(GRAY_FONT_COLOR:GetRGB()) })
		local colors = C_UIColor.GetColors()
		assert.equals("NORMAL_FONT_COLOR", colors[1].baseTag)

		assert.is_false(issecurevariable(_G, "UIParent"))
		assert.equals("Low", LOW)
		assert.equals("number", type(time()))
		assert.equals("string", type(date("%H:%M")))

		assert.is_false(IsLoggedIn())
		Mock.FireEvent("PLAYER_LOGIN")
		assert.is_true(IsLoggedIn())

		local guid = UnitGUID("player")
		assert.equals("Player-1-00000001", guid)
		assert.same({ "Warrior", "WARRIOR", "Human", "Human", 2, "Tester", "TestRealm" }, { GetPlayerInfoByGUID(guid) })
		assert.is_nil(GetPlayerInfoByGUID("Player-1-99999999"))
		assert.same({ "WARRIOR", 1 }, { UnitClassBase("player") })
		assert.same({ className = "Mage", classFile = "MAGE", classID = 8 }, C_CreatureInfo.GetClassInfo(8))
		assert.equals(60, UnitLevel("player"))
		assert.equals(0, GetMoney())
		assert.equals("Stormwind City", GetZoneText())

		assert.equals(ChatFrame1, DEFAULT_CHAT_FRAME)
		assert.same({}, StaticPopupDialogs)
		assert.is_false(Menu.GetManager():IsAnyMenuOpen())
		assert.has_no_error(function() UIDropDownMenu_Initialize(DropDownList1, function() end) end)
		assert.is_false(DropDownList1:IsShown())
	end)
end)
