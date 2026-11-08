return {
  staging = {
    host = "myhost",
    password = "secret",
    mappings = {
      { ["local"] = ".", ["remote"] = "/var/www/staging" },
    },
  },
}
