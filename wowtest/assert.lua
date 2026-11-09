local Assert = {}

local function Describe(value)
	if type(value) == "string" then return string.format("%q", value) end
	return tostring(value)
end

local function IsMockObject(value)
	return type(value) == "table" and rawget(value, "__type") ~= nil
end

local function DeepEqual(a, b)
	if rawequal(a, b) then return true end
	if type(a) ~= "table" or type(b) ~= "table" or IsMockObject(a) or IsMockObject(b) then return false end
	for k, v in pairs(a) do
		if not DeepEqual(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function Dump(value, indent)
	if IsMockObject(value) then return "<mock " .. tostring(value.__type) .. ">" end
	if type(value) ~= "table" then return Describe(value) end
	indent = indent or ""
	local keys = {}
	for k in pairs(value) do keys[#keys + 1] = k end
	table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
	local lines = { "{" }
	for _, k in ipairs(keys) do
		lines[#lines + 1] = indent .. "  " .. tostring(k) .. " = " .. Dump(value[k], indent .. "  ")
	end
	lines[#lines + 1] = indent .. "}"
	return table.concat(lines, "\n")
end

function Assert.Install(luaAssert)
	local assert = setmetatable({}, { __call = function(_, ...) return luaAssert(...) end })

	function assert.equals(expected, actual, message)
		if expected ~= actual then
			error((message and message .. ": " or "") .. "expected " .. Describe(expected) .. ", got " .. Describe(actual), 2)
		end
	end
	assert.are_equal = assert.equals

	function assert.same(expected, actual, message)
		if not DeepEqual(expected, actual) then
			error((message and message .. ": " or "") .. "expected\n" .. Dump(expected) .. "\ngot\n" .. Dump(actual), 2)
		end
	end
	assert.are_same = assert.same

	function assert.is_true(value, message)
		if value ~= true then error((message or "expected true") .. ", got " .. Describe(value), 2) end
	end

	function assert.is_false(value, message)
		if value ~= false then error((message or "expected false") .. ", got " .. Describe(value), 2) end
	end

	function assert.is_nil(value, message)
		if value ~= nil then error((message or "expected nil") .. ", got " .. Describe(value), 2) end
	end

	function assert.is_not_nil(value, message)
		if value == nil then error(message or "expected a value, got nil", 2) end
	end

	function assert.has_error(fn, message)
		if pcall(fn) then error(message or "expected an error", 2) end
	end

	function assert.has_no_error(fn, message)
		local ok, err = pcall(fn)
		if not ok then error((message and message .. ": " or "") .. "unexpected error: " .. tostring(err), 2) end
	end

	return assert
end

Assert.DeepEqual = DeepEqual
Assert.Dump = Dump

return Assert
