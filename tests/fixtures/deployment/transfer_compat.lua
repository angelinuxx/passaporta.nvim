-- A realistic transfer.nvim-style config (Laravel project, two remotes on the same host).
return {
  staging = {
    host = "example-host",
    username = "web",
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/staging.example.com" },
    },
    excludedPaths = { "vendor", "node_modules", ".env", "**/*.http" },
  },
  production = {
    host = "example-host",
    username = "web",
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/example.com" },
    },
    excludedPaths = { "vendor", "node_modules", ".env", "**/*.http" },
    upload_on_save = false,
  },
}
