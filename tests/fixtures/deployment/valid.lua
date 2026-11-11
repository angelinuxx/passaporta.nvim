return {
  staging = {
    host = "myhost",
    username = "web",
    port = 2222,
    mappings = {
      { ["local"] = "./src/", ["remote"] = "/var/www/staging/" },
    },
  },
  production = {
    host = "myhost",
    username = "u12345",
    protocol = "sftp",
    password = true,
    mappings = {
      { ["local"] = ".", ["remote"] = "/" },
    },
    excludedPaths = { "vendor" },
  },
}
