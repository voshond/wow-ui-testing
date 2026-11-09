local Helpers = require("spec.mock.helpers")
local Mock = Helpers.Mock

describe("wowmock API enforcement", function()
	before_each(function()
		Mock.ClearExtensions()
		Mock.Install()
	end)

	after_each(function()
		Mock.ClearExtensions()
	end)

	it("rejects an undocumented widget method", function()
		local frame = CreateFrame("Frame", nil, UIParent)
		local ok, err = pcall(function() frame:SetMadeUpThing(1) end)
		assert.is_false(ok)
		assert.is_not_nil(tostring(err):find("Frame:SetMadeUpThing is not a documented method", 1, true), err)
	end)

	it("records documented methods it does not implement", function()
		local frame = CreateFrame("Frame", nil, UIParent)
		frame:SetClampedToScreen(true)
		assert.same({ "SetClampedToScreen", true }, frame.__calls[#frame.__calls])
	end)

	it("needs a template for template-only methods", function()
		local plain = CreateFrame("Frame", nil, UIParent)
		assert.has_error(function() plain:SetBackdrop({}) end)
		local templated = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
		assert.has_no_error(function() templated:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" }) end)
	end)

	it("checks documented function arguments", function()
		Mock.InstallUI()
		local ok, err = pcall(UnitHealth)
		assert.is_false(ok)
		assert.is_not_nil(tostring(err):find("UnitHealth: argument 1", 1, true), err)
	end)

	it("wraps globals an extension installs", function()
		Mock.Extend("Probe", { install = function(mock)
			mock.probeInstalled = true
			_G.UnitLevel = function() return 1 end
		end })
		Mock.Install()
		assert.is_true(Mock.probeInstalled)
		assert.has_error(function() UnitLevel() end)
		assert.equals(1, UnitLevel("player"))
	end)

	it("runs installUI steps and replaces extensions by name", function()
		local runs = {}
		Mock.Extend("Probe", { installUI = function() runs[#runs + 1] = "first" end })
		Mock.Extend("Probe", { installUI = function() runs[#runs + 1] = "second" end })
		Mock.InstallUI()
		assert.same({ "second" }, runs)
	end)

	it("switches to another snapshot file", function()
		local API = Mock.API
		local default = API.SNAPSHOT
		local file = os.tmpname()
		local handle = io.open(file, "w")
		handle:write('return { version = "0", functions = {}, enums = {}, events = {}, scriptObjects = {}, '
			.. 'lua = { globals = {}, methods = {}, called = {} } }')
		handle:close()
		API.UseSnapshot(file)
		assert.equals("0", API.Snapshot().version)
		assert.is_nil(API.Function("UnitHealth"))
		API.UseSnapshot(default)
		os.remove(file)
		assert.is_not_nil(API.Function("UnitHealth"))
	end)
end)
