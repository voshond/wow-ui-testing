return {
	specs = { "spec/fixtures/runner/checks", { dir = "spec/fixtures/runner/pkg", prefix = "pkg" } },
	pattern = "*_check.lua",
	path = { "./spec/fixtures/runner/lib/?.lua" },
	setup = "spec/fixtures/runner/setup.lua",
}
