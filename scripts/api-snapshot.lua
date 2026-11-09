--[[
Generates a client API snapshot from a wow-ui-source checkout: the full
documented client API (Blizzard_APIDocumentationGenerated), every global and
mixin method Blizzard's Lua defines, the undocumented engine functions and
methods it calls, and the client's Lua VM additions.

  luajit scripts/api-snapshot.lua [wow-ui-source dir] [output file]

Defaults: .client-source/forever, wowmock/snapshots/forever-<version>.lua.
Run from the repository root after updating the source checkout to a new
client build, then review the diff: it is the API change list. wowmock/api.lua
holds the mock to the snapshot.
]]
local sourceDir = arg[1] or ".client-source/forever"
local docsDir = sourceDir .. "/Interface/AddOns/Blizzard_APIDocumentationGenerated"

local function Lines(command)
	local list, pipe = {}, assert(io.popen(command))
	for line in pipe:lines() do list[#list + 1] = line end
	pipe:close()
	return list
end

local function Read(path)
	local file = assert(io.open(path))
	local text = file:read("*a")
	file:close()
	return text
end

local version = Read(sourceDir .. "/version.txt"):match("^%s*(.-)%s*$")
local outFile = arg[2] or "wowmock/snapshots/forever-" .. version .. ".lua"

-- Every identifier the mock mentions: Lua evidence is only kept for these.
local mockWords = {}
for _, path in ipairs(Lines("find wowmock -name '*.lua' -not -path 'wowmock/snapshots/*' | LC_ALL=C sort")) do
	for word in Read(path):gmatch("[%a_][%w_]*") do mockWords[word] = true end
end

-- Documentation files reference Enum/Constants while defining themselves.
local Proxy
local function Expression() return Proxy("<expression>") end
function Proxy(path)
	return setmetatable({}, {
		__index = function(_, key) return Proxy(path .. "." .. key) end,
		__tostring = function() return path end,
		__add = Expression, __sub = Expression, __mul = Expression, __div = Expression,
		__unm = Expression, __concat = Expression,
	})
end

local systems = {}
for _, path in ipairs(Lines("find '" .. docsDir .. "' -name '*.lua' | LC_ALL=C sort")) do
	local env = setmetatable({
		APIDocumentation = { AddDocumentationTable = function(_, t) systems[#systems + 1] = t end },
	}, { __index = function(_, key) return Proxy(key) end })
	local chunk = assert(loadfile(path))
	setfenv(chunk, env)
	chunk()
end

-- "name:Type", with "?" when the argument may be omitted (nilable or defaulted).
local function Field(arg)
	return arg.Name .. ":" .. tostring(arg.Type) .. ((arg.Nilable or arg.Default ~= nil) and "?" or "")
end

local NOT_CONDITIONS = { SecretReturns = true, SecretArguments = true, SecretAccessor = true,
	SecretReturnsForAspect = true, SecretArgumentsAddAspect = true, SecretValue = true, SecretPayloads = true }

-- Widget methods keep only their secret and protection rules: overloads
-- (SetPoint) make their documented argument lists unsuitable for checks.
local function Compact(fn, method, system)
	local def = { system = system }
	if not method and fn.Arguments and #fn.Arguments > 0 then
		def.args = {}
		for i, arg in ipairs(fn.Arguments) do def.args[i] = Field(arg) end
	end
	if not method and fn.Returns and #fn.Returns > 0 then
		def.returns = {}
		for i, ret in ipairs(fn.Returns) do def.returns[i] = Field(ret) end
	end
	def.secretArguments = fn.SecretArguments
	def.secretReturns = fn.SecretReturns or nil
	def.protected = fn.IsProtectedFunction or nil
	for key, value in pairs(fn) do
		local condition = not NOT_CONDITIONS[key] and key:match("^Secret(.+)$")
		if condition and value == true then
			def.secretWhen = def.secretWhen or {}
			def.secretWhen[#def.secretWhen + 1] = condition:gsub("^When", "")
		end
	end
	if def.secretWhen then table.sort(def.secretWhen) end
	for key, out in pairs({ SecretReturnsForAspect = "secretAspects", SecretArgumentsAddAspect = "addsAspects" }) do
		if fn[key] then
			def[out] = {}
			for i, aspect in ipairs(fn[key]) do def[out][i] = tostring(aspect):match("([^.]+)$") end
		end
	end
	return def
end

local snapshot = { version = version, functions = {}, enums = {}, events = {}, scriptObjects = {},
	lua = { globals = {}, methods = {}, called = {} } }
for _, system in ipairs(systems) do
	if system.Type == "ScriptObject" then
		local methods = {}
		for _, fn in ipairs(system.Functions or {}) do methods[fn.Name] = Compact(fn, true) end
		snapshot.scriptObjects[system.Name] = methods
	else
		for _, fn in ipairs(system.Functions or {}) do
			-- A function's own Namespace overrides its system's; "" is global.
			local namespace = fn.Namespace
			if namespace == nil then namespace = system.Namespace end
			if namespace == "" then namespace = nil end
			snapshot.functions[namespace and namespace .. "." .. fn.Name or fn.Name] = Compact(fn, false, system.Name)
		end
		for _, event in ipairs(system.Events or {}) do snapshot.events[event.LiteralName] = true end
	end
	for _, t in ipairs(system.Tables or {}) do
		if t.Type == "Enumeration" then
			local values = {}
			for _, field in ipairs(t.Fields or {}) do values[field.Name] = field.EnumValue end
			snapshot.enums[t.Name] = values
		end
	end
end

--[[
Blizzard's Lua, four kinds of evidence that a name exists in the client:
  globals   global functions and variables, and fields of capitalised global
            tables ("AuraUtil.GetAuraBorderColor"); mixin fields only when the
            mock defines that mixin ("BackdropTemplateMixin.SetBackdrop")
  methods   mixin methods (template methods such as SetBackdrop); one example owner
  called    undocumented engine functions and methods Blizzard code calls
            (GetQuestUiMapID, hooksecurefunc, :AddDoubleLine): existence only
  builtins  the client's Lua VM additions (BUILTINS below)
]]
local docsPrefix = sourceDir .. "/Interface/AddOns/Blizzard_APIDocumentation"
local KEYWORDS = {}
for word in ("and break do else elseif end false for function if in local nil not or repeat return then true"
	.. " until while"):gmatch("%a+") do KEYWORDS[word] = true end

-- Names a file binds itself (locals, loop variables, parameters): calling
-- one is no evidence of client API.
local function FileLocals(text)
	local names = {}
	local function Add(list)
		for name in list:gmatch("[%a_][%w_]*") do names[name] = true end
	end
	for list in text:gmatch("local%s+function%s+([%w_]+)") do Add(list) end
	for list in text:gmatch("local%s+([%w_,%s]-)%s*[=\n;]") do Add(list) end
	for list in text:gmatch("for%s+([%w_,%s]-)%s+in[%s(]") do Add(list) end
	for list in text:gmatch("for%s+([%w_]+)%s*=") do Add(list) end
	for list in text:gmatch("function%s*[%w_.:]*%s*%(([^)]*)%)") do Add(list) end
	return names
end

local calls = {}
for _, path in ipairs(Lines("find '" .. sourceDir .. "/Interface' -name '*.lua' | LC_ALL=C sort")) do
	if path:sub(1, #docsPrefix) ~= docsPrefix then
		local relative = path:sub(#sourceDir + 2)
		local text = Read(path):gsub("%-%-%[(=*)%[.-%]%1%]", "")
		local locals = FileLocals(text)
		for line in text:gmatch("[^\n]+") do
			local name = line:match("^function%s+([%w_]+)%s*%(") or line:match("^([%w_]+)%s*=[^=]")
			local owner, key = line:match("^%s*function%s+([%w_]+)%.([%w_]+)%s*%(")
			if not owner then owner, key = line:match("^%s*([%w_]+)%.([%w_]+)%s*=[^=]") end
			local mixin, method = line:match("^%s*function%s+([%w_]+):([%w_]+)%s*%(")
			if name and not KEYWORDS[name] then
				snapshot.lua.globals[name] = snapshot.lua.globals[name] or relative
			elseif owner and owner:match("^[A-Z]") and not locals[owner] then
				local full = owner .. "." .. key
				snapshot.lua.globals[full] = snapshot.lua.globals[full] or relative
			elseif mixin then
				local first = snapshot.lua.methods[method]
				if not first or mixin < first then snapshot.lua.methods[method] = mixin end
				-- The mock may also define the mixin table itself ("BackdropTemplateMixin").
				if mixin:match("^[A-Z]") and mockWords[mixin] and mockWords[method] then
					local full = mixin .. "." .. method
					snapshot.lua.globals[full] = snapshot.lua.globals[full] or relative
				end
			end
			-- Calls in code only: strings and comments mention words followed by "(".
			local code = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"):gsub("%-%-.*$", "")
			if code:match("%S") then
				for call in (" " .. code):gmatch("[^%w_.:]([%w_]+)%s*%(") do
					-- Lua's own globals are not client API.
					if not KEYWORDS[call] and not locals[call] and _G[call] == nil then
						calls[call] = calls[call] or relative
					end
				end
				for call in code:gmatch(":([%w_]+)%s*%(") do
					calls[":" .. call] = calls[":" .. call] or relative
				end
				-- Engine namespaces the docs leave out (C_PetBattles.IsInBattle).
				for call in (" " .. code):gmatch("[^%w_.:](C_[%w_]+%.[%w_]+)%s*%(") do
					calls[call] = calls[call] or relative
				end
			end
		end
	end
end
for name, relative in pairs(calls) do
	local method = name:match("^:(.+)$")
	if method then
		if not snapshot.lua.methods[method] then snapshot.lua.called[name] = relative end
	elseif not snapshot.functions[name] and not snapshot.lua.globals[name] then
		snapshot.lua.called[name] = relative
	end
end

-- The client's Lua VM additions: globals its C side defines (library
-- aliases and WoW's own Lua functions, warcraft.wiki.gg/wiki/Lua_functions).
-- No Lua file defines them and some no Blizzard file calls.
local BUILTINS = [[
	abs acos asin atan atan2 ceil cos deg exp floor frexp ldexp log log10 max min mod rad random fastrandom sin sqrt tan
	format gmatch gsub strbyte strchar strcmputf8i strconcat strfind strjoin strlen strlenutf8 strlower strmatch strrep
	strrev strsplit strsplittable strsub strtrim strupper tostringall
	foreach foreachi getn sort tinsert tremove wipe
	date time difftime
	hooksecurefunc securecall securecallfunction secureexecuterange issecure issecurevariable forceinsecure
	seterrorhandler geterrorhandler debugstack debuglocals getprinthandler setprinthandler
]]
snapshot.lua.builtins = {}
for name in BUILTINS:gmatch("%S+") do snapshot.lua.builtins[name] = true end
for name in pairs(snapshot.lua.builtins) do snapshot.lua.called[name] = nil end

-- Filter components aura containers accept (AuraUtil.IsValidFilterString).
snapshot.lua.auraFilters = {}
local auraFilters = assert(Read(sourceDir .. "/Interface/AddOns/Blizzard_FrameXMLUtil/AuraUtil.lua")
	:match("AuraUtil%.AuraFilters%s*=%s*(%b{})"), "AuraUtil.AuraFilters not found")
for component in auraFilters:gmatch('=%s*"([%u_]+)"') do snapshot.lua.auraFilters[component] = true end

-- Serialization: sorted keys, one entry per line, for reviewable diffs.
local function Keys(t)
	local keys = {}
	for key in pairs(t) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function Key(key)
	if type(key) == "string" and key:match("^[%a_][%w_]*$") and not KEYWORDS[key] then return key end
	return "[" .. string.format("%q", key) .. "]"
end

local function Inline(value)
	if type(value) == "string" then return string.format("%q", value) end
	if type(value) ~= "table" then return tostring(value) end
	local parts = {}
	if #value > 0 then
		for _, item in ipairs(value) do parts[#parts + 1] = Inline(item) end
	else
		for _, key in ipairs(Keys(value)) do parts[#parts + 1] = Key(key) .. " = " .. Inline(value[key]) end
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

local out = {
	"-- Generated by scripts/api-snapshot.lua from wow-ui-source " .. version .. ". Do not edit by hand.",
	"return {",
	"\tversion = " .. string.format("%q", version) .. ",",
}
local function Section(name, t, depth)
	local indent = string.rep("\t", depth)
	out[#out + 1] = indent .. Key(name) .. " = {"
	for _, key in ipairs(Keys(t)) do
		local value = t[key]
		if type(value) == "table" and depth == 1 and (name == "scriptObjects" or name == "lua") then
			Section(key, value, depth + 1)
		else
			out[#out + 1] = indent .. "\t" .. Key(key) .. " = " .. Inline(value) .. ","
		end
	end
	out[#out + 1] = indent .. "},"
end
for _, name in ipairs({ "functions", "enums", "events", "scriptObjects", "lua" }) do
	Section(name, snapshot[name], 1)
end
out[#out + 1] = "}"

local file = assert(io.open(outFile, "w"))
file:write(table.concat(out, "\n"), "\n")
file:close()
local counts = {}
for _, name in ipairs({ "functions", "enums", "events" }) do
	counts[#counts + 1] = #Keys(snapshot[name]) .. " " .. name
end
print(string.format("Wrote %s (%s, %s)", outFile, version, table.concat(counts, ", ")))
