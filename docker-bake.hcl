variable "PLATFORMS" {
  default = ["linux/amd64", "linux/arm64"]
}

group "default" {
  targets = ["image", "debug"]
}

target "docker-metadata-action" {}
target "docker-metadata-action-debug" {}

target "image" {
  inherits = ["docker-metadata-action"]
  platforms = PLATFORMS
}

target "debug" {
  inherits = ["docker-metadata-action-debug"]
  target = "debug"
  platforms = PLATFORMS
}
