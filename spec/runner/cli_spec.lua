local Config = require("wowtest.config")

local function Run(args, config)
	local command = Config.Quote(arg[-1] or "luajit") .. " wowtest/cli.lua --config "
		.. (config or "spec/fixtures/runner/wut.config.lua") .. " " .. args .. " 2>&1; echo \"exit=$?\""
	local handle = io.popen(command)
	local output = handle:read("*a")
	handle:close()
	return output, tonumber(output:match("exit=(%d+)%s*$"))
end

local function Has(output, text)
	return output:find(text, 1, true) ~= nil
end

describe("wowtest cli", function()
	it("runs every spec dir and fails on a failing test", function()
		local output, code = Run("")
		assert.equals(1, code, output)
		assert.is_true(Has(output, "Running 3 spec files"), output)
		assert.is_true(Has(output, "4 passed, 1 failed, 0 syntax errors"), output)
		assert.is_true(Has(output, "FAIL beta fails on purpose #broken"), output)
	end)

	it("passes when the filters leave out the failing test", function()
		local output, code = Run("--tag fast --tag slow")
		assert.equals(0, code, output)
		assert.is_true(Has(output, "3 passed, 0 failed"), output)
	end)

	it("narrows by test name with -t", function()
		local output, code = Run("-t 'adds numbers'")
		assert.equals(0, code, output)
		assert.is_true(Has(output, "1 passed, 0 failed"), output)
	end)

	it("narrows by folder, file and prefixed package", function()
		assert.is_true(Has(Run("nested/"), "Running 1 spec file\n"))
		assert.is_true(Has(Run("alpha_check.lua"), "Running 1 spec file\n"))
		local output, code = Run("pkg/")
		assert.equals(0, code, output)
		assert.is_true(Has(output, "1 passed, 0 failed"), output)
	end)

	it("fails a run that selects no tests", function()
		local output, code = Run("-t 'no such test'")
		assert.equals(1, code, output)
		assert.is_true(Has(output, "No tests matched the given filters."), output)
	end)

	it("runs spec files in parallel with -j and reports --times", function()
		local output, code = Run("-j 2 --times --tag fast --tag slow")
		assert.equals(0, code, output)
		assert.is_true(Has(output, "in 2 processes"), output)
		assert.is_true(Has(output, "(total, wall clock)"), output)
		assert.is_true(Has(output, "3 passed, 0 failed"), output)
	end)

	it("isolates globals between spec files in a serial run", function()
		local output = Run("gamma alpha")
		assert.is_true(Has(output, "3 passed, 0 failed"), output)
		assert.is_nil(LEAKED_GLOBAL)
	end)

	it("counts syntax errors in the configured files", function()
		local output, code = Run("--tag fast", "spec/fixtures/runner/broken.config.lua")
		assert.equals(1, code, output)
		assert.is_true(Has(output, "Syntax check: 1 files, 1 errors"), output)
	end)

	it("rejects unknown options and a missing config", function()
		assert.equals(2, select(2, Run("--bogus")))
		assert.equals(2, select(2, Run("", "missing.lua")))
	end)
end)
