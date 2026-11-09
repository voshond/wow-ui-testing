local Raster = {}

local function Quote(text)
	return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end
Raster.Quote = Quote

local function Run(command)
	local result = os.execute(command)
	return result == 0 or result == true
end
Raster.Run = Run

local tools = {}
function Raster.Has(tool)
	if tools[tool] == nil then tools[tool] = Run("command -v " .. Quote(tool) .. " >/dev/null 2>&1") end
	return tools[tool]
end

function Raster.MakeDir(dir)
	if not Run("mkdir -p " .. Quote(dir)) then error("wowproof: can't create " .. dir, 2) end
end

function Raster.Exists(file)
	local handle = io.open(file, "rb")
	if not handle then return false end
	handle:close()
	return true
end

function Raster.Write(file, content)
	local handle = assert(io.open(file, "wb"))
	handle:write(content)
	handle:close()
end

function Raster.Read(file)
	local handle = io.open(file, "rb")
	if not handle then return nil end
	local content = handle:read("*a")
	handle:close()
	return content
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function Raster.Base64(data)
	local out = {}
	for index = 1, #data, 3 do
		local a, b, c = data:byte(index, index + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local d1 = math.floor(n / 262144) % 64
		local d2 = math.floor(n / 4096) % 64
		local d3 = math.floor(n / 64) % 64
		local d4 = n % 64
		out[#out + 1] = ALPHABET:sub(d1 + 1, d1 + 1) .. ALPHABET:sub(d2 + 1, d2 + 1)
			.. (b and ALPHABET:sub(d3 + 1, d3 + 1) or "=")
			.. (c and ALPHABET:sub(d4 + 1, d4 + 1) or "=")
	end
	return table.concat(out)
end

local function CacheName(file)
	return (file:gsub("[^%w%-_.]+", "_")) .. ".png"
end

function Raster.ImageTool()
	if Raster.Has("magick") then return "magick" end
	if Raster.Has("convert") then return "convert" end
	return nil
end

function Raster.ToPng(file, cacheDir)
	if file:lower():match("%.png$") then return Raster.Exists(file) and file or nil end
	local tool = Raster.ImageTool()
	if not tool or not Raster.Exists(file) then return nil end
	Raster.MakeDir(cacheDir)
	local target = cacheDir .. "/" .. CacheName(file)
	if Raster.Exists(target) then return target end
	if not Run(tool .. " " .. Quote(file) .. " " .. Quote(target) .. " >/dev/null 2>&1") then return nil end
	return target
end

local function UInt32(data, offset)
	local a, b, c, d = data:byte(offset, offset + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

function Raster.PngSize(png)
	local data = Raster.Read(png)
	if not data or #data < 24 or data:sub(13, 16) ~= "IHDR" then return nil end
	return UInt32(data, 17), UInt32(data, 21)
end

function Raster.DataUri(png)
	local data = Raster.Read(png)
	if not data then return nil end
	return "data:image/png;base64," .. Raster.Base64(data)
end

local FONTS_CONF = [[<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
%s<include ignore_missing="yes">/etc/fonts/fonts.conf</include>
<cachedir>%s</cachedir>
</fontconfig>
]]

local function Absolute(path)
	if path:sub(1, 1) == "/" then return path end
	local handle = io.popen("pwd")
	local cwd = handle:read("*l")
	handle:close()
	return cwd .. "/" .. path
end
Raster.Absolute = Absolute

function Raster.FontConfig(dirs, cacheDir)
	Raster.MakeDir(cacheDir)
	local entries = {}
	for _, dir in ipairs(dirs or {}) do
		entries[#entries + 1] = "<dir>" .. Absolute(dir) .. "</dir>\n"
	end
	local file = Absolute(cacheDir .. "/fonts.conf")
	Raster.Write(file, string.format(FONTS_CONF, table.concat(entries), Absolute(cacheDir .. "/fontcache")))
	return file
end

function Raster.SvgToPng(svg, png, scale, fontConfig)
	if not Raster.Has("rsvg-convert") then return nil end
	local env = fontConfig and ("FONTCONFIG_FILE=" .. Quote(fontConfig) .. " ") or ""
	local command = string.format("%srsvg-convert -z %s -o %s %s", env, tostring(scale or 1), Quote(png), Quote(svg))
	if not Run(command) then return nil end
	return png
end

return Raster
