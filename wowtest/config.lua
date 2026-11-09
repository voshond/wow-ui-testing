local Config = {}

Config.DEFAULT_FILES = { "wut.config.lua", "tests/wut.config.lua" }

local function Quote(text)
	return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function WithSlash(dir)
	return dir:sub(-1) == "/" and dir or dir .. "/"
end

local function List(value, field)
	if value == nil then return {} end
	if type(value) == "string" then return { value } end
	if type(value) ~= "table" then error("config." .. field .. " must be a string or a list", 0) end
	return value
end

function Config.Normalize(raw)
	if type(raw) ~= "table" then error("config must return a table", 0) end
	local specs = {}
	for index, entry in ipairs(List(raw.specs, "specs")) do
		if type(entry) == "string" then entry = { dir = entry } end
		if type(entry.dir) ~= "string" then error("config.specs[" .. index .. "] needs a dir", 0) end
		specs[#specs + 1] = { dir = WithSlash(entry.dir), prefix = entry.prefix and WithSlash(entry.prefix) or "" }
	end
	if #specs == 0 then error("config.specs names no spec dir", 0) end
	local syntax = raw.syntax or {}
	return {
		specs = specs,
		pattern = raw.pattern or "*_spec.lua",
		path = List(raw.path, "path"),
		setup = raw.setup,
		syntax = { include = List(syntax.include, "syntax.include"), exclude = List(syntax.exclude, "syntax.exclude") },
	}
end

function Config.Find(explicit, exists)
	if explicit then return explicit end
	for _, file in ipairs(Config.DEFAULT_FILES) do
		if exists(file) then return file end
	end
	error("no config found (tried " .. table.concat(Config.DEFAULT_FILES, ", ") .. "); pass --config FILE", 0)
end

function Config.Load(file)
	local chunk, err = loadfile(file)
	if not chunk then error("cannot load config " .. err, 0) end
	return Config.Normalize(chunk())
end

function Config.SpecPath(config, key)
	for _, entry in ipairs(config.specs) do
		if entry.prefix ~= "" and key:sub(1, #entry.prefix) == entry.prefix then
			return entry.dir .. key:sub(#entry.prefix + 1)
		end
	end
	for _, entry in ipairs(config.specs) do
		if entry.prefix == "" then return entry.dir .. key end
	end
	error("no spec dir for " .. key, 0)
end

function Config.SpecKey(entry, path)
	return entry.prefix .. path:sub(#entry.dir + 1)
end

function Config.FindSpecsCommand(config, entry)
	return "find " .. Quote(entry.dir) .. " -name " .. Quote(config.pattern)
end

function Config.SyntaxCommand(config)
	if #config.syntax.include == 0 then return nil end
	local parts = { "find" }
	for _, root in ipairs(config.syntax.include) do parts[#parts + 1] = Quote(root) end
	parts[#parts + 1] = "-name '*.lua'"
	for _, pattern in ipairs(config.syntax.exclude) do parts[#parts + 1] = "-not -path " .. Quote(pattern) end
	return table.concat(parts, " ")
end

Config.Quote = Quote

return Config
