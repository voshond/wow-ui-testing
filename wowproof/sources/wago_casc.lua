local Raster = require("wowproof.raster")
local Blp = require("wowproof.blp")

local DEFAULT_URL = "https://wago.tools/api/casc/%d?version=%s"

local function FileId(file)
	if type(file) == "number" then return file % 1 == 0 and file > 0 and file or nil end
	if type(file) == "string" and file:match("^%d+$") then return tonumber(file) end
	return nil
end

return function(options)
	options = options or {}
	local build = options.build or error("wowproof: pin the CASC source to a client build (build)", 2)
	local dir = (options.dir or ".proof-art") .. "/casc-" .. build
	local fetch = options.fetch ~= false
	local url = options.url or DEFAULT_URL

	return function(file)
		local id = FileId(file)
		if not id then return nil end
		local cached = string.format("%s/%d.png", dir, id)
		if Raster.Exists(cached) then return cached end
		if not fetch or not Raster.Has("curl") then return nil end
		local blp = string.format("%s/%d.blp", dir, id)
		if not Raster.Download(string.format(url, id, build), blp) then return nil end
		local width, height, rgba = Blp.Decode(Raster.Read(blp))
		os.remove(blp)
		if not width then return nil end
		return Raster.RawToPng(rgba, width, height, cached)
	end
end
