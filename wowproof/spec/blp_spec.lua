local Blp = require("wowproof.blp")

local function UInt32(value)
	return string.char(value % 256, math.floor(value / 256) % 256, math.floor(value / 65536) % 256, math.floor(value / 16777216))
end

local function File(compression, alphaDepth, alphaType, width, height, body, palette)
	return "BLP2" .. UInt32(1) .. string.char(compression, alphaDepth, alphaType, 0) .. UInt32(width) .. UInt32(height)
		.. UInt32(1172) .. string.rep(UInt32(0), 15) .. UInt32(#body) .. string.rep(UInt32(0), 15)
		.. (palette or "") .. string.rep("\0", 1024 - #(palette or "")) .. body
end

local function Bytes(text)
	return { text:byte(1, -1) }
end

local RED_BLUE = "\0\248\31\0"

describe("wowproof BLP2 decoder", function()
	it("swizzles uncompressed BGRA to RGBA", function()
		local width, height, rgba = Blp.Decode(File(3, 8, 8, 2, 1, "\3\2\1\4\7\6\5\8"))
		assert.equals(2, width)
		assert.equals(1, height)
		assert.same({ 1, 2, 3, 4, 5, 6, 7, 8 }, Bytes(rgba))
	end)

	it("looks palette pixels up with 8-bit and 1-bit alpha", function()
		local palette = "\30\20\10\0\60\50\40\0"
		local _, _, rgba = Blp.Decode(File(1, 8, 0, 2, 1, "\0\1\128\255", palette))
		assert.same({ 10, 20, 30, 128, 40, 50, 60, 255 }, Bytes(rgba))
		_, _, rgba = Blp.Decode(File(1, 1, 0, 2, 1, "\0\1\2", palette))
		assert.same({ 10, 20, 30, 0, 40, 50, 60, 255 }, Bytes(rgba))
		_, _, rgba = Blp.Decode(File(1, 0, 0, 1, 1, "\1", palette))
		assert.same({ 40, 50, 60, 255 }, Bytes(rgba))
	end)

	it("decodes DXT1 blocks, clipped to the image, with the transparent three-colour mode", function()
		local _, _, rgba = Blp.Decode(File(2, 0, 0, 2, 2, RED_BLUE .. UInt32(4)))
		assert.same({ 255, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255, 255, 0, 0, 255 }, Bytes(rgba))
		_, _, rgba = Blp.Decode(File(2, 1, 0, 1, 1, "\31\0\0\248" .. UInt32(3)))
		assert.same({ 0, 0, 0, 0 }, Bytes(rgba))
	end)

	it("decodes DXT3 and DXT5 alpha", function()
		local _, _, rgba = Blp.Decode(File(2, 8, 1, 1, 1, "\8" .. string.rep("\0", 7) .. RED_BLUE .. UInt32(0)))
		assert.same({ 255, 0, 0, 136 }, Bytes(rgba))
		_, _, rgba = Blp.Decode(File(2, 8, 7, 2, 1, "\255\0\1\0\0\0\0\0" .. RED_BLUE .. UInt32(0)))
		assert.same({ 255, 0, 0, 0, 255, 0, 0, 255 }, Bytes(rgba))
	end)

	it("rejects other files and encodings", function()
		assert.is_nil(Blp.Decode("PNG"))
		assert.is_nil(Blp.Decode(File(2, 8, 5, 1, 1, string.rep("\0", 16))))
		assert.is_nil(Blp.Decode(File(3, 8, 8, 2, 2, "\0\0\0\0")))
	end)
end)
