describe("alpha #fast", function()
	local order = {}
	before_each(function() order[#order + 1] = "before" end)
	after_each(function() order[#order + 1] = "after" end)

	it("adds numbers", function()
		assert.equals(2, 1 + 1)
	end)

	it("runs hooks around each test", function()
		assert.same({ "before", "after", "before" }, order)
	end)
end)
