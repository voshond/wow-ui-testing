local Helpers = require("spec.mock.helpers")
local Mock = Helpers.Mock
local Proof = require("wowproof")
local Raster = require("wowproof.raster")
local MockState = require("wowproof.adapters.mock_state")

describe("wowproof on wowmock", function()
	it("renders a frame built on the mock through the mock_state adapter", function()
		local ns = Helpers.LoadSample()
		local bar = ns.CreateBar(UIParent)
		local adapter = MockState({
			isSecret = Mock.IsSecret,
			reveal = function(value) return value.secretValue end,
			objects = function() return Mock.objects end,
			globals = _G,
		})
		assert.same({ min = 0, max = 100, value = 25, reverse = false, color = { 0, 1, 0, 1 },
			file = "Interface\\Buttons\\WHITE8X8" }, adapter.Bar(bar))
		local dir = io.popen("mktemp -d"):read("*l")
		local proof = Proof.New({ adapter = adapter, outDir = dir, png = false, title = "wowmock" })
		local entry = proof:Snapshot(bar, "sample bar")
		local svg = Raster.Read(entry.svg)
		os.execute("rm -rf " .. Raster.Quote(dir))
		assert.is_not_nil(svg:find("<svg", 1, true))
		assert.is_not_nil(svg:find('width="30" height="16" fill="rgb(0,255,0)"', 1, true), svg)
	end)
end)
