local Raster = require("wowproof.raster")

local PNG_SIG = "\137PNG\r\n\26\n"

local function Chunk(typ, body)
	local len = #body
	return string.char(math.floor(len / 16777216) % 256, math.floor(len / 65536) % 256, math.floor(len / 256) % 256, len % 256)
		.. typ .. body .. "\0\0\0\0"
end

local function ChunkTypes(data)
	local types = {}
	local pos = 9
	while pos + 11 <= #data do
		local a, b, c, d = data:byte(pos, pos + 3)
		types[#types + 1] = data:sub(pos + 4, pos + 7)
		pos = pos + 12 + ((a * 256 + b) * 256 + c) * 256 + d
	end
	return types
end

local function Output(command)
	local handle = io.popen(command)
	local text = handle:read("*a")
	handle:close()
	return text
end

describe("wowproof Raster.StripPng", function()
	it("keeps the chunks that decide pixels, tRNS included, and drops the rest", function()
		local png = PNG_SIG .. Chunk("IHDR", ("\0"):rep(13)) .. Chunk("tIME", ("\0"):rep(7)) .. Chunk("PLTE", ("\0"):rep(6))
			.. Chunk("tRNS", "\0\255") .. Chunk("tEXt", "date:create\0now") .. Chunk("IDAT", "pixels") .. Chunk("IEND", "")
		assert.same({ "IHDR", "PLTE", "tRNS", "IDAT", "IEND" }, ChunkTypes(Raster.StripPng(png)))
	end)

	it("leaves an indexed PNG with transparency transparent", function()
		local tool = Raster.ImageTool()
		if not tool then return end
		local scratch = Output("mktemp -d"):gsub("%s+$", "")
		local source = scratch .. "/indexed.png"
		local stripped = scratch .. "/stripped.png"
		assert.is_true(Raster.Run(string.format("%s -size 4x1 xc:none -fill red -draw 'point 0,0' %s PNG8:%s >/dev/null 2>&1",
			tool, Raster.PNG_OUTPUT, Raster.Quote(source))))
		local data = Raster.Read(source)
		Raster.Write(stripped, Raster.StripPng(data))
		local alpha = Output(string.format("%s %s -alpha extract -format '%%[fx:minima]' info: 2>/dev/null",
			tool, Raster.Quote(stripped)))
		os.execute("rm -rf " .. Raster.Quote(scratch))

		assert.is_not_nil(data:find("tRNS", 1, true), "ImageMagick wrote the indexed PNG's alpha in tRNS")
		assert.equals(0, tonumber(alpha), "a transparent pixel turned opaque after StripPng")
	end)
end)
