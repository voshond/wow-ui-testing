--[[
Loads an addon into the mock the way the client does: every file its TOC
lists, in order, with (addonName, ns) as the chunk varargs. XML files only
contribute their <Script file=...> and <Include file=...> entries.

Files are read and compiled once per process. Calling a compiled chunk again
runs its main body afresh (new locals and closures), so every load still
starts from a clean state.
]]
local Mock = require("wowmock")

local Loader = { skip = {} }

local chunks, includes, tocs = {}, {}, {}

-- Path fragments never loaded (libraries replaced by stand-ins in specs).
function Loader.Skip(patterns)
	Loader.skip = patterns or {}
end

local function Skipped(path)
	for _, pattern in ipairs(Loader.skip) do
		if path:find(pattern, 1, true) then return true end
	end
	return false
end

local function Compile(path)
	local chunk = chunks[path]
	if not chunk then
		chunk = assert(loadfile(path))
		chunks[path] = chunk
	end
	return chunk
end

local function XmlIncludes(path)
	local files = includes[path]
	if not files then
		local dir = path:match("^(.*)/[^/]+$")
		local handle = assert(io.open(path))
		local xml = handle:read("*a")
		handle:close()
		files = {}
		for file in xml:gmatch('<%a+%s+file%s*=%s*["\']([^"\']+)["\']') do
			files[#files + 1] = dir .. "/" .. file:gsub("\\", "/")
		end
		includes[path] = files
	end
	return files
end

function Loader.TocFiles(tocPath)
	local files = tocs[tocPath]
	if not files then
		local dir = tocPath:match("^(.*)/[^/]+$")
		files = {}
		for line in io.lines(tocPath) do
			line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
			if line ~= "" and not line:match("^#") then
				files[#files + 1] = dir .. "/" .. line:gsub("\\", "/")
			end
		end
		tocs[tocPath] = files
	end
	return files
end

local function LoadFile(path, addonName, ns)
	if Skipped(path) then return end
	if path:match("%.xml$") then
		for _, file in ipairs(XmlIncludes(path)) do LoadFile(file, addonName, ns) end
	elseif path:match("%.lua$") then
		Compile(path)(addonName, ns)
	else
		error("wowmock can't load " .. path)
	end
end

function Loader.LoadToc(tocPath, addonName, ns)
	ns = ns or {}
	for _, file in ipairs(Loader.TocFiles(tocPath)) do LoadFile(file, addonName, ns) end
	Mock.loadedAddons[addonName] = true
	return ns
end

return Loader
