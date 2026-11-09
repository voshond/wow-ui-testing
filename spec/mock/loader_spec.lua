local Helpers = require("spec.mock.helpers")
local Mock, Loader = Helpers.Mock, Helpers.Loader

describe("wowmock loader", function()
	local ns

	before_each(function()
		ns = Helpers.LoadSample()
	end)

	it("loads the TOC's files in order through XML, skipping configured paths", function()
		assert.same({
			"spec/fixtures/addon/SampleAddon/Libs/Skipped/Skipped.lua",
			"spec/fixtures/addon/SampleAddon/SampleAddon.xml",
			"spec/fixtures/addon/SampleAddon/Events.lua",
		}, Loader.TocFiles(Helpers.TOC))
		assert.equals("SampleAddon", ns.name)
		assert.equals(1, ns.loads)
		assert.is_true(Mock.loadedAddons.SampleAddon)
	end)

	it("passes a caller's namespace and reloads chunks afresh", function()
		local shared = { loads = 5 }
		Loader.LoadToc(Helpers.TOC, "SampleAddon", shared)
		assert.equals(6, shared.loads)
	end)

	it("fires events to registered frames", function()
		Mock.FireEvent("ADDON_LOADED", "SampleAddon")
		Mock.FireEvent("PLAYER_LOGIN")
		Mock.FireEvent("PLAYER_LOGOUT")
		assert.same({ { "ADDON_LOADED", "SampleAddon" }, { "PLAYER_LOGIN" } }, ns.events)
		assert.equals(1, SampleAddonDB.loaded)
		assert.is_true(Mock.registeredEvents.PLAYER_LOGIN)
	end)

	it("holds C_Timer.After callbacks until a spec runs them", function()
		Mock.FireEvent("ADDON_LOADED", "SampleAddon")
		assert.is_nil(ns.timerRan)
		assert.equals(1, #Mock.timers)
		Mock.RunTimers()
		assert.is_true(ns.timerRan)
		assert.equals(0, #Mock.timers)
	end)

	it("clears an extension's globals on every install", function()
		Mock.FireEvent("ADDON_LOADED", "SampleAddon")
		assert.is_not_nil(SampleAddonDB)
		Helpers.LoadSample()
		assert.is_nil(SampleAddonDB)
	end)
end)
