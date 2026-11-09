--[[
Loads an addon into the mock the way the client does: every file its TOC
lists, in order, with (addonName, ns) as the chunk varargs. XML files run
through wowmock.xml: their scripts and includes load in document order, and
their frames and templates are built on the mock.

Files are read and compiled once per process. Calling a compiled chunk again
runs its main body afresh (new locals and closures), so every load still
starts from a clean state.
]]
local Mock = require("wowmock")
local Xml = require("wowmock.xml")

local Loader = { skip = {} }

local chunks, documents, tocs = {}, {}, {}

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

local BOM = "\239\187\191"

-- Like the client, a leading UTF-8 byte order mark is skipped.
local function Compile(path)
	local chunk = chunks[path]
	if not chunk then
		local handle = assert(io.open(path, "rb"))
		local source = handle:read("*a")
		handle:close()
		if source:sub(1, 3) == BOM then source = source:sub(4) end
		chunk = assert(loadstring(source, "@" .. path))
		chunks[path] = chunk
	end
	return chunk
end

-- Parsed once per process; the parser drops comments like the client
-- (Ace3's AceConfig-3.0.xml has a commented-out include).
local function XmlDocument(path)
	local document = documents[path]
	if not document then
		local handle = assert(io.open(path, "rb"))
		local text = handle:read("*a")
		handle:close()
		if text:sub(1, 3) == BOM then text = text:sub(4) end
		document = Xml.Parse(text, path)
		documents[path] = document
	end
	return document
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
		Xml.Load(XmlDocument(path), path, function(file) LoadFile(file, addonName, ns) end)
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

-- Third-party addons fetched by scripts/fetch-wut.sh, and the flavour TOC
-- suffixes the client prefers over a plain Name.toc.
Loader.addonsDir = ".wut/addons"
Loader.tocSuffixes = { "_Vanilla", "-Vanilla", "_Classic", "-Classic" }

local function Exists(path)
	local handle = io.open(path)
	if handle then handle:close() end
	return handle ~= nil
end

local function FirstLine(path)
	local handle = io.open(path)
	if not handle then return nil end
	local line = handle:read("*l")
	handle:close()
	return line and line:match("^%s*(.-)%s*$")
end

-- The TOC the client would load for `base` ("Dir/Name.toc").
function Loader.ResolveToc(base)
	local stem = base:gsub("%.toc$", "")
	for _, suffix in ipairs(Loader.tocSuffixes) do
		if Exists(stem .. suffix .. ".toc") then return stem .. suffix .. ".toc" end
	end
	if Exists(base) then return base end
	error("no TOC for " .. base, 2)
end

-- Loads a fetched third-party addon by its wut.config.lua name, through the
-- TOC its config entry names (or <name>.toc). The addon name passed to its
-- files is the TOC's folder, like the client's. Returns ns and that name.
function Loader.LoadAddon(name, ns)
	local dir = Loader.addonsDir .. "/" .. name
	local toc = Loader.ResolveToc(dir .. "/" .. (FirstLine(dir .. "/.wut-toc") or name .. ".toc"))
	local addonName = toc:match("([^/]+)/[^/]+$")
	return Loader.LoadToc(toc, addonName, ns), addonName
end

return Loader
