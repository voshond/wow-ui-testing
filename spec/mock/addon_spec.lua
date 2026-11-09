local Helpers = require("spec.mock.helpers")
local Mock, Loader = Helpers.Mock, Helpers.Loader

describe("wowmock third-party addons", function()
	local addonsDir

	before_each(function()
		addonsDir = Loader.addonsDir
		Loader.addonsDir = "spec/fixtures/addons"
		Mock.Extend("Panel", { globals = { "PanelRegistry", "SamplePlugin" } })
		Mock.Install()
	end)

	after_each(function()
		Loader.addonsDir = addonsDir
		Mock.ClearExtensions()
	end)

	it("prefers the flavour TOC over the plain one", function()
		assert.equals("spec/fixtures/addons/Panel/Panel/Panel_Vanilla.toc",
			Loader.ResolveToc("spec/fixtures/addons/Panel/Panel/Panel.toc"))
		assert.equals(Helpers.TOC, Loader.ResolveToc(Helpers.TOC))
		assert.has_error(function() Loader.ResolveToc("spec/fixtures/addons/Missing/Missing.toc") end)
	end)

	it("loads a fetched addon before the addon under test, and each sees the other's globals", function()
		local _, panelName = Loader.LoadAddon("Panel")
		Loader.LoadToc("spec/fixtures/addon/SamplePlugin/SamplePlugin.toc", "SamplePlugin")
		assert.equals("Panel", panelName)
		assert.is_true(Mock.loadedAddons.Panel)
		assert.equals("Panel", SamplePlugin.panelOwner)
		assert.same({ "SamplePlugin" }, PanelRegistry.plugins)
		Mock.FireEvent("PLAYER_LOGIN")
		assert.is_true(SamplePlugin.ready)
	end)
end)
