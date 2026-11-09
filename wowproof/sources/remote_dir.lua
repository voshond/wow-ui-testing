local Raster = require("wowproof.raster")

local function IsUrl(remote)
	return remote:match("^https?://") ~= nil
end

local function CopyCommand(remote, name, partial)
	local host, dir = remote:match("^([%w%._@%-]+):(.+)$")
	if host then
		if not Raster.Has("ssh") then return nil end
		return "ssh -o BatchMode=yes -o ConnectTimeout=5 " .. Raster.Quote(host) .. " "
			.. Raster.Quote("cat " .. Raster.Quote(dir .. "/" .. name)) .. " > " .. Raster.Quote(partial) .. " 2>/dev/null"
	end
	return "cp " .. Raster.Quote(remote .. "/" .. name) .. " " .. Raster.Quote(partial) .. " 2>/dev/null"
end

local function Copy(remote, name, target)
	if IsUrl(remote) then
		return Raster.Has("curl") and Raster.Download(remote .. "/" .. name, target)
	end
	Raster.MakeDir(target:match("^(.*)/[^/]+$") or ".")
	local partial = target .. ".part"
	local command = CopyCommand(remote, name, partial)
	if not command or not Raster.Run(command) or not Raster.NonEmpty(partial) then
		os.remove(partial)
		return false
	end
	os.rename(partial, target)
	return true
end

return function(options)
	options = options or {}
	local remote = options.remote
	local dir = options.dir or error("wowproof: give the remote folder a cache dir (dir)", 2)
	local fetch = options.fetch ~= false and remote ~= nil and remote ~= ""
	local tried = {}

	return function(name)
		if type(name) ~= "string" or name:find("%.%.") or name:sub(1, 1) == "/" then return nil end
		local cached = dir .. "/" .. name
		if Raster.Exists(cached) then return cached end
		if not fetch or tried[name] then return nil end
		tried[name] = true
		if not Copy((remote:gsub("/$", "")), name, cached) then return nil end
		return cached
	end
end
