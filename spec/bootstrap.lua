package.path = "./?.lua;./?/init.lua;" .. package.path

local function Describe(value)
	return type(value) == "string" and string.format("%q", value) or tostring(value)
end

local function DeepEqual(a, b)
	if rawequal(a, b) then return true end
	if type(a) ~= "table" or type(b) ~= "table" or rawget(a, "__type") or rawget(b, "__type") then return false end
	for k, v in pairs(a) do
		if not DeepEqual(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

local function Check(ok, message, default)
	if not ok then error(message or default, 3) end
end

local luaAssert = assert
assert = setmetatable({}, { __call = function(_, ...) return luaAssert(...) end })
assert.equals = function(expected, actual, message)
	Check(expected == actual, message, "expected " .. Describe(expected) .. ", got " .. Describe(actual))
end
assert.same = function(expected, actual, message) Check(DeepEqual(expected, actual), message, "tables differ") end
assert.is_true = function(value, message) Check(value == true, message, "expected true, got " .. Describe(value)) end
assert.is_false = function(value, message) Check(value == false, message, "expected false, got " .. Describe(value)) end
assert.is_nil = function(value, message) Check(value == nil, message, "expected nil, got " .. Describe(value)) end
assert.is_not_nil = function(value, message) Check(value ~= nil, message, "expected a value, got nil") end
assert.has_error = function(fn, message) Check(not pcall(fn), message, "expected an error") end

local root = { tests = {}, before = {}, after = {} }
local current = root

describe = function(name, body)
	local block = { name = name, tests = {}, before = {}, after = {}, parent = current }
	table.insert(current.tests, { block = block })
	local previous = current
	current = block
	body()
	current = previous
end
it = function(name, body) table.insert(current.tests, { name = name, body = body }) end
before_each = function(fn) table.insert(current.before, fn) end
after_each = function(fn) table.insert(current.after, fn) end

local passed, failures = 0, {}

local function Hooks(block, field, out)
	if block.parent then Hooks(block.parent, field, out) end
	for _, fn in ipairs(block[field]) do out[#out + 1] = fn end
	return out
end

local function RunBlock(block, prefix)
	for _, test in ipairs(block.tests) do
		if test.block then
			RunBlock(test.block, prefix .. test.block.name .. " ")
		else
			local ok, err = xpcall(function()
				for _, fn in ipairs(Hooks(block, "before", {})) do fn() end
				test.body()
				local after = Hooks(block, "after", {})
				for i = #after, 1, -1 do after[i]() end
			end, debug.traceback)
			if ok then
				passed = passed + 1
			else
				failures[#failures + 1] = prefix .. test.name .. "\n    " .. tostring(err):gsub("\n", "\n    ")
			end
		end
	end
end

local handle = io.popen("find wowproof/spec -name '*_spec.lua' | sort")
for file in handle:lines() do
	root = { tests = {}, before = {}, after = {} }
	current = root
	local ok, err = xpcall(function() dofile(file) end, debug.traceback)
	if ok then RunBlock(root, "") else failures[#failures + 1] = file .. " failed to load\n    " .. tostring(err) end
	print(file)
end
handle:close()

for _, failure in ipairs(failures) do print("FAIL " .. failure) end
print(string.format("%d passed, %d failed", passed, #failures))
os.exit((#failures == 0 and passed > 0) and 0 or 1, true)
