local Mock = require("wowmock")
local Loader = require("wowmock.loader")

local Helpers = { Mock = Mock, Loader = Loader }

Helpers.TOC = "spec/fixtures/addon/SampleAddon/SampleAddon.toc"

Helpers.LoadSample = function()
	Mock.Extend("SampleAddon", { globals = { "SampleAddonDB" } })
	Mock.Install()
	Mock.InstallUI()
	Loader.Skip({ "Libs/Skipped/" })
	return Loader.LoadToc(Helpers.TOC, "SampleAddon")
end

return Helpers
