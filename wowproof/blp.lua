local ffi = require("ffi")
local bit = require("bit")

local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

local Blp = {}

local HEADER_SIZE = 1172
local PALETTE_OFFSET = 148
local COMPRESSION_PALETTE, COMPRESSION_DXT, COMPRESSION_RAW = 1, 2, 3
local DXT1, DXT3, DXT5 = 0, 1, 7

local function UInt16(bytes, offset)
	return bor(bytes[offset], lshift(bytes[offset + 1], 8))
end

local function UInt32(bytes, offset)
	return bytes[offset] + bytes[offset + 1] * 256 + bytes[offset + 2] * 65536 + bytes[offset + 3] * 16777216
end

local function Expand565(color)
	local r, g, b = band(rshift(color, 11), 31), band(rshift(color, 5), 63), band(color, 31)
	return math.floor(r * 255 / 31 + 0.5), math.floor(g * 255 / 63 + 0.5), math.floor(b * 255 / 31 + 0.5)
end

local function Mix(a, b, weightA, weightB, total)
	return math.floor((a * weightA + b * weightB) / total + 0.5)
end

local function ColorPalette(bytes, offset, fourColor)
	local c0, c1 = UInt16(bytes, offset), UInt16(bytes, offset + 2)
	local r0, g0, b0 = Expand565(c0)
	local r1, g1, b1 = Expand565(c1)
	local palette = { { r0, g0, b0, 255 }, { r1, g1, b1, 255 } }
	if fourColor or c0 > c1 then
		palette[3] = { Mix(r0, r1, 2, 1, 3), Mix(g0, g1, 2, 1, 3), Mix(b0, b1, 2, 1, 3), 255 }
		palette[4] = { Mix(r0, r1, 1, 2, 3), Mix(g0, g1, 1, 2, 3), Mix(b0, b1, 1, 2, 3), 255 }
	else
		palette[3] = { Mix(r0, r1, 1, 1, 2), Mix(g0, g1, 1, 1, 2), Mix(b0, b1, 1, 1, 2), 255 }
		palette[4] = { 0, 0, 0, 0 }
	end
	return palette
end

local function Dxt3Alpha(bytes, offset)
	local alphas = {}
	for index = 0, 15 do
		local byte = bytes[offset + rshift(index, 1)]
		alphas[index] = band(rshift(byte, band(index, 1) * 4), 15) * 17
	end
	return alphas
end

local function Dxt5Alpha(bytes, offset)
	local a0, a1 = bytes[offset], bytes[offset + 1]
	local levels = { [0] = a0, a1 }
	if a0 > a1 then
		for step = 2, 7 do levels[step] = Mix(a0, a1, 8 - step, step - 1, 7) end
	else
		for step = 2, 5 do levels[step] = Mix(a0, a1, 6 - step, step - 1, 5) end
		levels[6], levels[7] = 0, 255
	end
	local alphas = {}
	for half = 0, 1 do
		local base = offset + 2 + half * 3
		local bits = bytes[base] + bytes[base + 1] * 256 + bytes[base + 2] * 65536
		for index = 0, 7 do alphas[half * 8 + index] = levels[band(rshift(bits, index * 3), 7)] end
	end
	return alphas
end

local function DecodeDxt(bytes, offset, width, height, alphaType, out)
	local blockSize = alphaType == DXT1 and 8 or 16
	local blocksWide, blocksHigh = math.ceil(width / 4), math.ceil(height / 4)
	for blockY = 0, blocksHigh - 1 do
		for blockX = 0, blocksWide - 1 do
			local block = offset + (blockY * blocksWide + blockX) * blockSize
			local alphas
			if alphaType == DXT3 then alphas = Dxt3Alpha(bytes, block) elseif alphaType == DXT5 then alphas = Dxt5Alpha(bytes, block) end
			local colorOffset = alphaType == DXT1 and block or block + 8
			local palette = ColorPalette(bytes, colorOffset, alphaType ~= DXT1)
			local indices = UInt32(bytes, colorOffset + 4)
			for index = 0, 15 do
				local x, y = blockX * 4 + index % 4, blockY * 4 + math.floor(index / 4)
				if x < width and y < height then
					local color = palette[band(rshift(indices, index * 2), 3) + 1]
					local target = (y * width + x) * 4
					out[target], out[target + 1], out[target + 2] = color[1], color[2], color[3]
					out[target + 3] = alphas and alphas[index] or color[4]
				end
			end
		end
	end
end

local function PaletteAlpha(bytes, offset, index, depth)
	if depth == 8 then return bytes[offset + index] end
	if depth == 4 then return band(rshift(bytes[offset + rshift(index, 1)], band(index, 1) * 4), 15) * 17 end
	if depth == 1 then return band(rshift(bytes[offset + rshift(index, 3)], band(index, 7)), 1) * 255 end
	return 255
end

local function DecodePalette(bytes, offset, pixels, alphaDepth, out)
	for index = 0, pixels - 1 do
		local entry = PALETTE_OFFSET + bytes[offset + index] * 4
		local target = index * 4
		out[target], out[target + 1], out[target + 2] = bytes[entry + 2], bytes[entry + 1], bytes[entry]
		out[target + 3] = PaletteAlpha(bytes, offset + pixels, index, alphaDepth)
	end
end

local function DecodeRaw(bytes, offset, pixels, out)
	for index = 0, pixels - 1 do
		local source, target = offset + index * 4, index * 4
		out[target], out[target + 1], out[target + 2], out[target + 3] =
			bytes[source + 2], bytes[source + 1], bytes[source], bytes[source + 3]
	end
end

local function ExpectedSize(compression, alphaDepth, alphaType, width, height)
	local pixels = width * height
	if compression == COMPRESSION_RAW then return pixels * 4 end
	if compression == COMPRESSION_PALETTE then return pixels + math.ceil(pixels * alphaDepth / 8) end
	if compression == COMPRESSION_DXT and (alphaType == DXT1 or alphaType == DXT3 or alphaType == DXT5) then
		return math.ceil(width / 4) * math.ceil(height / 4) * (alphaType == DXT1 and 8 or 16)
	end
	return nil
end

function Blp.Decode(data)
	if type(data) ~= "string" or #data < HEADER_SIZE or data:sub(1, 4) ~= "BLP2" then return nil, "not a BLP2 file" end
	local bytes = ffi.cast("const uint8_t*", data)
	local compression, alphaDepth, alphaType = bytes[8], bytes[9], bytes[10]
	local width, height = UInt32(bytes, 12), UInt32(bytes, 16)
	local offset, size = UInt32(bytes, 20), UInt32(bytes, 84)
	local expected = ExpectedSize(compression, alphaDepth, alphaType, width, height)
	if not expected then return nil, string.format("unsupported BLP2 encoding %d/%d", compression, alphaType) end
	if width == 0 or height == 0 or size < expected or offset + expected > #data then return nil, "truncated BLP2 file" end
	local pixels = width * height
	local out = ffi.new("uint8_t[?]", pixels * 4)
	if compression == COMPRESSION_RAW then
		DecodeRaw(bytes, offset, pixels, out)
	elseif compression == COMPRESSION_PALETTE then
		DecodePalette(bytes, offset, pixels, alphaDepth, out)
	else
		DecodeDxt(bytes, offset, width, height, alphaType, out)
	end
	return width, height, ffi.string(out, pixels * 4)
end

return Blp
