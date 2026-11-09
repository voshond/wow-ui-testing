local print = print
local SCRIPT = arg[0]
local LIB_ROOT = SCRIPT:match("^(.*)/wowtest/cli%.lua$") or "."
local INTERPRETER = arg[-1] or "luajit"
package.path = LIB_ROOT .. "/?.lua;" .. LIB_ROOT .. "/?/init.lua;" .. package.path

local Args = require("wowtest.args")
local Assert = require("wowtest.assert")
local Config = require("wowtest.config")
local Filter = require("wowtest.filter")
local Suite = require("wowtest.suite")
local Quote = Config.Quote

local ok, options = pcall(Args.Parse, arg)
if not ok then
	io.stderr:write(options, "\n\n", Args.USAGE, "\n")
	os.exit(2)
end
if options.help then
	print(Args.USAGE)
	os.exit(0)
end

local Now = os.clock
do
	local hasFfi, ffi = pcall(require, "ffi")
	if hasFfi then
		ffi.cdef("typedef struct { long tv_sec; long tv_nsec; } wowtest_timespec; int clock_gettime(int, wowtest_timespec *);")
		local spec = ffi.new("wowtest_timespec")
		Now = function()
			ffi.C.clock_gettime(1, spec)
			return tonumber(spec.tv_sec) + tonumber(spec.tv_nsec) / 1e9
		end
	end
end
local startedAt = Now()

local function Lines(command)
	local lines = {}
	local handle = io.popen(command)
	for line in handle:lines() do lines[#lines + 1] = line end
	handle:close()
	return lines
end

local function ListFiles(command)
	local files = Lines(command)
	table.sort(files)
	return files
end

local function Exists(file)
	local handle = io.open(file)
	if handle then handle:close() end
	return handle ~= nil
end

local configOk, configFile = pcall(Config.Find, options.config, Exists)
local config
if configOk then
	configOk, config = pcall(Config.Load, configFile)
end
if not configOk then
	io.stderr:write(config or configFile, "\n")
	os.exit(2)
end

local hostPath = {}
for _, entry in ipairs(config.path) do hostPath[#hostPath + 1] = entry .. ";" end
package.path = table.concat(hostPath) .. "./?.lua;./?/init.lua;" .. package.path

assert = Assert.Install(assert)
Suite.InstallDSL(_G)
if config.setup then dofile(config.setup) end

local filters = { names = options.names, tags = options.tags }

local function ReportFile(result)
	local tests = result.passed + result.failed
	if tests == 0 then return end
	local counts = result.failed > 0 and string.format("%d passed, %d failed", result.passed, result.failed)
		or string.format("%d passed", result.passed)
	io.write(string.format("  %-4s %-52s %-22s %6.2fs\n", result.failed > 0 and "FAIL" or "ok",
		result.file, counts, result.seconds))
	io.flush()
end

if options.child then
	local key = options.paths[1]
	local result = Suite.RunFile(key, Config.SpecPath(config, key), filters, Now)
	ReportFile(result)
	local out = io.open(options.child, "w")
	out:write(string.format("return { file = %q, passed = %d, failed = %d, seconds = %.6f, failures = {\n",
		result.file, result.passed, result.failed, result.seconds))
	for _, failure in ipairs(result.failures) do out:write(string.format("%q,\n", failure)) end
	out:write("} }\n")
	out:close()
	os.exit(0, true)
end

local syntaxErrors, syntaxSeconds = 0, 0
local syntaxCommand = Config.SyntaxCommand(config)
if syntaxCommand then
	local files = ListFiles(syntaxCommand)
	for _, file in ipairs(files) do
		local _, err = loadfile(file)
		if err then
			syntaxErrors = syntaxErrors + 1
			print("syntax error: " .. err)
		end
	end
	syntaxSeconds = Now() - startedAt
	print(string.format("Syntax check: %d files, %d errors (%.2fs)", #files, syntaxErrors, syntaxSeconds))
end

local files = {}
for _, entry in ipairs(config.specs) do
	for _, path in ipairs(ListFiles(Config.FindSpecsCommand(config, entry))) do
		local key = Config.SpecKey(entry, path)
		if Filter.SpecSelected(key, options.paths) then files[#files + 1] = key end
	end
end

local jobs = options.jobs
if jobs == 0 then
	jobs = tonumber(Lines("nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1")[1]) or 1
end

local parallel = jobs and jobs > 1 and #files > 1
print(string.format("Running %d spec file%s%s", #files, #files == 1 and "" or "s",
	parallel and string.format(" in %d processes", jobs) or ""))
io.flush()

local results, passed, failed, failures = {}, 0, 0, {}

local function Collect(result)
	results[#results + 1] = result
	passed, failed = passed + result.passed, failed + result.failed
	for _, failure in ipairs(result.failures) do failures[#failures + 1] = failure end
end

if parallel then
	local dir = Lines("mktemp -d")[1]
	local order = {}
	for index, key in ipairs(files) do
		local handle = io.open(Config.SpecPath(config, key))
		order[index] = { index = index, key = key, size = handle:seek("end") }
		handle:close()
	end
	table.sort(order, function(a, b) return a.size > b.size end)
	local list = io.open(dir .. "/files", "w")
	for _, entry in ipairs(order) do list:write(dir, "/", entry.index, ".lua ", entry.key, "\n") end
	list:close()
	local forward = { "--config", Quote(configFile) }
	for _, text in ipairs(options.names) do forward[#forward + 1] = "-t " .. Quote(text) end
	for _, tag in ipairs(options.tags) do forward[#forward + 1] = "--tag " .. Quote(tag) end
	local child = "exec " .. Quote(INTERPRETER) .. " " .. Quote(SCRIPT) .. " " .. table.concat(forward, " ")
		.. ' --child "$0" "$1"'
	os.execute(string.format("xargs -P %d -L 1 sh -c %s < %s", jobs, Quote(child), Quote(dir .. "/files")))
	for index, key in ipairs(files) do
		local chunk = loadfile(dir .. "/" .. index .. ".lua")
		Collect(chunk and chunk() or { file = key, passed = 0, failed = 1, seconds = 0,
			failures = { key .. " did not report a result (the spec process crashed)" } })
	end
	os.execute("rm -rf " .. Quote(dir))
else
	for _, key in ipairs(files) do
		Collect(Suite.RunFile(key, Config.SpecPath(config, key), filters, Now))
		ReportFile(results[#results])
	end
end

print()
if options.times then
	table.sort(results, function(a, b) return a.seconds > b.seconds end)
	print(string.format("%8s %6s %9s  %s", "seconds", "tests", "per test", "spec"))
	for _, result in ipairs(results) do
		local tests = result.passed + result.failed
		print(string.format("%8.2f %6d %9.3f  %s", result.seconds, tests, result.seconds / math.max(tests, 1), result.file))
	end
	if syntaxCommand then print(string.format("%8.2f %6s %9s  %s", syntaxSeconds, "", "", "(syntax check)")) end
	print(string.format("%8.2f %6d %9s  %s", Now() - startedAt, passed + failed, "", "(total, wall clock)"))
end
for _, failure in ipairs(failures) do print("FAIL " .. failure) end
local selectedNothing = passed + failed == 0
if selectedNothing then print("No tests matched the given filters.") end
print(string.format("%d passed, %d failed, %d syntax errors", passed, failed, syntaxErrors))
os.exit((failed == 0 and syntaxErrors == 0 and not selectedNothing) and 0 or 1, true)
