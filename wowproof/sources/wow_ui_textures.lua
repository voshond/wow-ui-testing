local Raster = require("wowproof.raster")

local DEFAULT_REPOSITORY = "Gethe/wow-ui-textures"

local function UrlEncode(text)
	return (text:gsub("[^%w%-_%.~/]", function(char) return string.format("%%%02X", char:byte()) end))
end

return function(options)
	options = options or {}
	local repository = options.repository or DEFAULT_REPOSITORY
	local ref = options.ref or error("wowproof: pin the art source to a commit (ref)", 2)
	local dir = options.dir or ".proof-art"
	local fetch = options.fetch ~= false
	local token = options.token
	local treesDir = dir .. "/trees"
	local filesDir = dir .. "/" .. ref
	local missingFile = dir .. "/missing-" .. ref .. ".txt"
	local trees, missing = {}, nil

	local function Download(url, target, api)
		local headers = { "User-Agent: wowproof" }
		if api then headers[#headers + 1] = "Accept: application/vnd.github+json" end
		if api and token and token ~= "" then headers[#headers + 1] = "Authorization: Bearer " .. token end
		return Raster.Download(url, target, headers)
	end

	local function Tree(sha)
		if trees[sha] then return trees[sha] end
		local file = treesDir .. "/" .. sha .. ".tsv"
		if not Raster.Exists(file) then
			if not fetch or not Raster.Has("curl") or not Raster.Has("jq") then return nil end
			local json = file .. ".json"
			if not Download(string.format("https://api.github.com/repos/%s/git/trees/%s", repository, sha), json, true) then
				return nil
			end
			local ok = Raster.Run("jq -r '.tree[] | [.type, .sha, .path] | @tsv' " .. Raster.Quote(json) .. " > "
				.. Raster.Quote(file .. ".part"))
			os.remove(json)
			if not ok then
				os.remove(file .. ".part")
				return nil
			end
			os.rename(file .. ".part", file)
		end
		local entries = {}
		for line in io.lines(file) do
			local kind, entrySha, name = line:match("^(%S+)\t(%S+)\t(.+)$")
			if kind then entries[name:upper()] = { kind = kind, sha = entrySha, name = name } end
		end
		trees[sha] = entries
		return entries
	end

	local function Missing()
		if missing then return missing end
		missing = {}
		if Raster.Exists(missingFile) then
			for line in io.lines(missingFile) do missing[line] = true end
		end
		return missing
	end

	local function MarkMissing(key)
		Missing()[key] = true
		Raster.MakeDir(dir)
		local handle = io.open(missingFile, "a")
		if handle then
			handle:write(key, "\n")
			handle:close()
		end
	end

	local function Locate(key)
		local entries = Tree(ref)
		if not entries then return nil, true end
		local parts = {}
		for part in key:gmatch("[^\\]+") do parts[#parts + 1] = part end
		local names = {}
		for index, part in ipairs(parts) do
			local last = index == #parts
			local entry = last and entries[part .. ".PNG"] or entries[part]
			if not entry or entry.kind ~= (last and "blob" or "tree") then return nil, false end
			names[#names + 1] = entry.name
			if not last then
				entries = Tree(entry.sha)
				if not entries then return nil, true end
			end
		end
		return table.concat(names, "/"), false
	end

	return function(path)
		if type(path) ~= "string" then return nil end
		local relative = path:gsub("/", "\\"):match("^[Ii][Nn][Tt][Ee][Rr][Ff][Aa][Cc][Ee]\\(.+)$")
		if not relative then return nil end
		local key = relative:gsub("%.[BbTt][LlGg][PpAa]$", ""):upper()
		local cached = filesDir .. "/" .. key:gsub("\\", "/") .. ".png"
		if Raster.Exists(cached) then return cached end
		if not fetch or Missing()[key] then return nil end
		local remote, transient = Locate(key)
		if not remote then
			if not transient then MarkMissing(key) end
			return nil
		end
		local url = string.format("https://raw.githubusercontent.com/%s/%s/%s", repository, ref, UrlEncode(remote))
		if not Download(url, cached) then return nil end
		return cached
	end
end
