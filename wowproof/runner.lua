local Runner = {}

local function Selected(name, filters)
	if not filters or #filters == 0 then return true end
	for _, filter in ipairs(filters) do
		if name:find(filter, 1, true) then return true end
	end
	return false
end

function Runner.Run(options)
	local proof, print = options.proof, options.print or print
	local passed, failed = 0, 0
	for _, scenario in ipairs(options.scenarios) do
		if Selected(scenario.name, options.filters) then
			local ok, err = xpcall(function()
				local region = scenario.build()
				local entry = proof:Snapshot(region, scenario.name, scenario.options)
				print(string.format("  ok   %-40s %s", scenario.name, entry.png or entry.svg))
			end, debug.traceback)
			if ok then
				passed = passed + 1
			else
				failed = failed + 1
				proof:Fail(scenario.name, err)
				print(string.format("  FAIL %s\n    %s", scenario.name, tostring(err):gsub("\n", "\n    ")))
			end
			if options.after then options.after(scenario) end
		end
	end
	local sheet = proof:Sheet()
	print(string.format("%d snapshots, %d failed: %s", passed, failed, sheet))
	return passed, failed, sheet
end

return Runner
