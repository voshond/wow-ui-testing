local Helpers = require("spec.mock.helpers")
local Mock = Helpers.Mock
local API = Mock.API

--[[
The mock against the client API snapshot (wowmock/api.lua). Behaviour is
hand-written and can still be wrong; these checks keep its surface, enums,
declared secrets and event names tied to Blizzard's documentation.
]]

-- Lua, LuaJIT and test runner globals: not client API.
local NOT_CLIENT = {}
for name in ([[_G _VERSION assert collectgarbage coroutine debug dofile error gcinfo getfenv getmetatable io
	ipairs jit load loadfile loadstring math module newproxy next os package pairs pcall print rawequal rawget
	rawset require select setfenv setmetatable string table tonumber tostring type unpack xpcall bit arg
	describe it before_each after_each]]):gmatch("%S+") do
	NOT_CLIENT[name] = true
end

-- Mock globals that are not client functions, with the reason.
local MOCK_ONLY = {
	Secret = "test helper creating fake secrets",
	["Mock.TickUnitVisibility"] = "test helper",
}

-- Documented, defined by Blizzard's Lua, or an engine function Blizzard calls.
local function IsClientFunction(name)
	return API.Function(name) or API.LuaGlobal(name) or API.Called(name)
end

describe("Client API contract", function()
	before_each(function()
		Mock.Install()
		Mock.InstallUI()
	end)

	it("mocks only documented or Blizzard-defined global functions", function()
		local unknown = {}
		for name, value in pairs(_G) do
			if not NOT_CLIENT[name] and not MOCK_ONLY[name] then
				if type(value) == "function" and not IsClientFunction(name) then
					unknown[#unknown + 1] = name
				elseif type(value) == "table" and rawget(value, "__type") == nil then
					for key, field in pairs(value) do
						local full = name .. "." .. key
						if type(key) == "string" and type(field) == "function" and not IsClientFunction(full)
							and not MOCK_ONLY[full] then
							unknown[#unknown + 1] = full
						end
					end
				end
			end
		end
		table.sort(unknown)
		assert.same({}, unknown, "mocked functions missing from the client API snapshot")
	end)

	it("mocks only documented widget methods and marks its test helpers", function()
		local unknown = {}
		for name in pairs(Mock.Methods) do
			local documented = Mock.HELPERS[name] or API.LuaMethod(name) or API.Called(":" .. name)
			for objectType in pairs(API.TYPES) do
				documented = documented or API.Method(objectType, name)
			end
			if not documented then unknown[#unknown + 1] = name end
		end
		table.sort(unknown)
		assert.same({}, unknown)
	end)

	it("gives native aura containers and buttons only their template methods", function()
		local container = CreateFrame("AuraContainer", nil, UIParent, "CustomAuraContainerTemplate")
		container:AddAuraGroup("buffs", "HELPFUL", { initializeFrame = function() end })
		local button = container:GetAuraGroupFrame("buffs", 1)
		local unknown = {}
		for _, object in ipairs({ container, button }) do
			for name, value in pairs(object) do
				if type(value) == "function" and not name:match("^Mock") and not API.LuaMethod(name)
					and not API.Method(object.__type, name) then
					unknown[#unknown + 1] = object.__type .. ":" .. name
				end
			end
		end
		table.sort(unknown)
		assert.same({}, unknown)
	end)

	it("uses the client's enum values", function()
		local enums = API.Snapshot().enums
		for enum, fields in pairs(Enum) do
			assert.is_not_nil(enums[enum], "Enum." .. enum .. " is not a client enum")
			for field, value in pairs(fields) do
				assert.equals(enums[enum][field], value, "Enum." .. enum .. "." .. field)
			end
		end
	end)

	-- Specs replace these per test; the restricted defaults stay plain.
	local PLAIN_DEFAULTS = {
		UnitInRange = "range results are configured per spec through Mock.ranges",
	}

	it("returns secrets from the restricted unit API wherever the client may", function()
		local plain = {}
		for name, def in pairs(API.Snapshot().functions) do
			local restricted = def.secretReturns
			for _, condition in ipairs(def.secretWhen or {}) do
				restricted = restricted or condition:match("^Unit") ~= nil
			end
			local takesUnit = def.args and def.args[1]:match(":UnitToken")
			local impl = not name:find(".", 1, true) and rawget(_G, name)
			if restricted and takesUnit and type(impl) == "function" and not PLAIN_DEFAULTS[name] then
				-- Every unit argument names the target (GetComboPoints takes two).
				local args = {}
				for i, arg in ipairs(def.args) do
					if arg:match(":UnitToken") then args[i] = "target" end
				end
				local results = { impl(unpack(args, 1, #def.args)) }
				for i = 1, table.maxn(results) do
					-- Only plain values can be secret; returned objects are opaque handles.
					local primitive = type(results[i]) ~= "table" or Mock.IsSecret(results[i])
					if results[i] ~= nil and primitive and not Mock.IsSecret(results[i]) then
						plain[#plain + 1] = name .. " return " .. i
					end
				end
			end
		end
		table.sort(plain)
		assert.same({}, plain, "the restricted mock returns plain values the client may keep secret")
	end)

	it("registers only documented events", function()
		Helpers.LoadSample()
		local undocumented = {}
		local documented = API.Snapshot().events
		for event in pairs(Mock.registeredEvents) do
			if not documented[event] then undocumented[#undocumented + 1] = event end
		end
		table.sort(undocumented)
		assert.is_true(Mock.registeredEvents.ADDON_LOADED)
		assert.same({}, undocumented)
	end)

	it("keeps addon code away from mock-only helpers", function()
		local pipe = assert(io.popen("grep -rnE ':(GetAnchor|RunScript|Mock[A-Z][A-Za-z]*)\\(|Mock\\.' "
			.. "spec/fixtures/addon --include='*.lua'"))
		local hits = pipe:read("*a")
		pipe:close()
		assert.equals("", hits)
	end)

	it("matches a snapshot regenerated from the local Blizzard source, when present", function()
		local source = ".client-source/forever"
		local version = io.open(source .. "/version.txt")
		if not version then
			assert.is_nil(os.getenv("WUT_REQUIRE_CLIENT_SOURCE"), source .. " is missing: run bash scripts/update-client-source.sh --sync")
			return
		end
		version:close()
		local out = os.tmpname()
		local pipe = assert(io.popen("luajit scripts/api-snapshot.lua " .. source .. " " .. out .. " 2>&1"))
		pipe:read("*a")
		pipe:close()
		local function Read(path)
			local file = assert(io.open(path))
			local text = file:read("*a")
			file:close()
			return text
		end
		local fresh = Read(out)
		os.remove(out)
		assert.is_true(fresh == Read(API.SNAPSHOT), API.SNAPSHOT .. " is stale: run luajit scripts/api-snapshot.lua")
	end)
end)
