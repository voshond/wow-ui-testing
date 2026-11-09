return {
	specs = {
		{ dir = "spec/" },
		{ dir = "wowproof/spec/", prefix = "wowproof/" },
	},
	syntax = { include = { "wowproof", "wowtest", "spec" }, exclude = { "spec/fixtures/runner/broken/*" } },
}
