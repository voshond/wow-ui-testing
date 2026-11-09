local Filter = require("wowtest.filter")

local Suite = {}

local function NewBlock(name, parent)
	return { name = name, tests = {}, before = {}, after = {}, parent = parent }
end

local root = NewBlock("")
local current = root

function Suite.InstallDSL(env)
	function env.describe(name, body)
		local block = NewBlock(name, current)
		table.insert(current.tests, { block = block })
		local previous = current
		current = block
		body()
		current = previous
	end

	function env.it(name, body)
		table.insert(current.tests, { name = name, body = body })
	end

	function env.before_each(fn)
		table.insert(current.before, fn)
	end

	function env.after_each(fn)
		table.insert(current.after, fn)
	end
end

local function Hooks(block, field, out)
	if block.parent then Hooks(block.parent, field, out) end
	for _, fn in ipairs(block[field]) do out[#out + 1] = fn end
	return out
end

local function Indent(err)
	return (tostring(err):gsub("\n", "\n    "))
end

local function RunBlock(block, prefix, filters, result)
	for _, test in ipairs(block.tests) do
		if test.block then
			RunBlock(test.block, prefix .. test.block.name .. " ", filters, result)
		elseif Filter.TestSelected(prefix .. test.name, filters.names, filters.tags) then
			local ok, err = xpcall(function()
				for _, fn in ipairs(Hooks(block, "before", {})) do fn() end
				test.body()
				local after = Hooks(block, "after", {})
				for i = #after, 1, -1 do after[i]() end
			end, debug.traceback)
			if ok then
				result.passed = result.passed + 1
			else
				result.failed = result.failed + 1
				result.failures[#result.failures + 1] = prefix .. test.name .. "\n    " .. Indent(err)
			end
		end
	end
end

local function RestoreGlobals(saved)
	for name in pairs(_G) do
		if saved[name] == nil then _G[name] = nil end
	end
	for name, value in pairs(saved) do _G[name] = value end
end

function Suite.RunFile(key, path, filters, now)
	local started = now()
	local result = { file = key, passed = 0, failed = 0, failures = {} }
	local globals = {}
	for name, value in pairs(_G) do globals[name] = value end
	root = NewBlock("")
	current = root
	local ok, err = xpcall(function() dofile(path) end, debug.traceback)
	if ok then
		RunBlock(root, "", filters, result)
	else
		result.failed = 1
		result.failures[1] = key .. " failed to load\n    " .. Indent(err)
	end
	RestoreGlobals(globals)
	result.seconds = now() - started
	return result
end

return Suite
