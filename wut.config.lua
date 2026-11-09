return {
	specs = {
		{ dir = "spec/" },
		{ dir = "wowproof/spec/", prefix = "wowproof/" },
	},
	syntax = {
		include = { "wowproof", "wowtest", "wowmock", "scripts", "spec" },
		exclude = { "spec/fixtures/runner/broken/*", "wowmock/snapshots/*" },
	},
}
