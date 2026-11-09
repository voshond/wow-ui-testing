local Helpers = require("spec.mock.helpers")
local Mock, Loader = Helpers.Mock, Helpers.Loader
local Xml = require("wowmock.xml")

local TOC = "spec/fixtures/addon/XmlAddon/XmlAddon.toc"

describe("wowmock XML", function()
	local ns

	before_each(function()
		Mock.ClearExtensions()
		Mock.Extend("XmlAddon", { globals = { "XmlAddonBom", "XmlAddonEntries", "XmlAddonLog", "XmlAddon_OnEvent" } })
		Mock.Install()
		Loader.Skip({})
		ns = Loader.LoadToc(TOC, "XmlAddon")
	end)

	after_each(function()
		Mock.ClearExtensions()
	end)

	it("skips a UTF-8 byte order mark at the start of a file", function()
		assert.equals("loaded past the byte order mark", XmlAddonBom)
	end)

	it("parses elements, attributes, entities, CDATA and comments", function()
		local document = Xml.Parse([=[<?xml version="1.0"?>
<Ui><!-- <Frame name="Gone"/> -->
	<Frame name="A" virtual="true"><Scripts><OnLoad><![CDATA[if a < b then end]]></OnLoad></Scripts></Frame>
	<Texture file='x&amp;y'/>
</Ui>]=])
		local ui = document.children[1]
		assert.equals("Ui", ui.tag)
		assert.equals(2, #ui.children)
		assert.equals("A", ui.children[1].attributes.name)
		assert.equals("if a < b then end", ui.children[1].children[1].children[1].text)
		assert.equals("x&y", ui.children[2].attributes.file)
		assert.has_error(function() Xml.Parse("<Ui><Frame></Ui>", "broken.xml") end)
	end)

	it("creates the frames XML declares, with layout, key values and child frames", function()
		assert.equals(ns.entries, XmlAddonEntries)
		local frame = XmlAddonFrame
		assert.equals("Frame", frame:GetObjectType())
		assert.equals(UIParent, frame:GetParent())
		assert.same({ 200, 50 }, { frame:GetSize() })
		assert.same({ "TOPLEFT", nil, "TOPLEFT", 10, -20 }, { frame:GetPoint(1) })
		assert.equals("panel", frame.kind)
		assert.equals(3, frame.limit)

		local button = XmlAddonFrameButton
		assert.equals(button, frame.Button)
		assert.equals(frame, button:GetParent())
		assert.is_false(button:IsShown())
		assert.same({ 40, 16 }, { button:GetSize() })
		assert.same({ "RIGHT", frame, "RIGHT", 0, 0 }, { button:GetPoint(1) })
		assert.equals(XmlAddonFrameButtonIcon, button.Icon)
		assert.equals("Interface\\Icons\\Sample", button.Icon:GetTexture())
		local text = button:GetFontString()
		assert.equals(XmlAddonFrameButtonText, text)
		assert.equals("Low", text:GetText())
		assert.same({ "LEFT", button.Icon, "RIGHT", 2, 0 }, { text:GetPoint(1) })
	end)

	it("runs template, child and parent OnLoad in the client's order, and wires handlers", function()
		assert.same({ "template OnLoad XmlAddonFrameButton", "child OnLoad", "parent OnLoad" }, XmlAddonEntries)
		XmlAddonFrameButton:RunScript("OnClick", "RightButton")
		assert.equals("RightButton", XmlAddonFrameButton.clicked)
		XmlAddonFrame:RegisterEvent("PLAYER_LOGIN")
		Mock.FireEvent("PLAYER_LOGIN")
		assert.equals("PLAYER_LOGIN", XmlAddonFrame.lastEvent)
	end)

	it("builds virtual templates into CreateFrame, then runs OnLoad", function()
		local made = CreateFrame("Button", "XmlMade", UIParent, "BackdropTemplate, XmlTextTemplate")
		assert.equals(XmlMadeIcon, made.Icon)
		assert.equals(XmlMadeText, made:GetFontString())
		assert.is_false(made:IsShown())
		assert.equals("template OnLoad XmlMade", XmlAddonEntries[#XmlAddonEntries])
		assert.has_no_error(function() made:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" }) end)
	end)

	it("lets a host register Lua templates the same way", function()
		Mock.templates.HostTemplate = function(frame) frame.host = true end
		local frame = CreateFrame("Frame", nil, UIParent, "HostTemplate")
		assert.is_true(frame.host)
	end)
end)
