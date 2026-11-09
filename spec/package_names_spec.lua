local ADDONS = { "unit" .. "frames", "unit" .. "-frames", "magic" .. "map", "social" .. "ite" }
local PACKAGES = { "wowtest", "wowmock", "clientdata", "scripts" }

local function Files()
	local files = {}
	local handle = io.popen("find " .. table.concat(PACKAGES, " ") .. " -type f -not -path 'wowmock/snapshots/*' 2>/dev/null")
	for file in handle:lines() do files[#files + 1] = file end
	handle:close()
	return files
end

describe("library packages", function()
	it("name none of the addons that use them", function()
		local files = Files()
		assert.is_true(#files > 0)
		for _, file in ipairs(files) do
			local handle = io.open(file)
			local content = handle:read("*a"):lower()
			handle:close()
			for _, name in ipairs(ADDONS) do
				assert.is_nil(content:find(name, 1, true), file .. " names the addon " .. name)
			end
		end
	end)
end)
