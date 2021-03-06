job "example" {
  datacenters = ["dc1"]

  group "sync" {
    count = "1"

    task "service" {
      driver = "docker"

      config {
        image = "${sync_container_image}"

        args = [
          "consul-terraform-sync",
          "-config-file",
          "/local/sync.hcl",
        ]
      }

      resources {
        cpu = 800
        memory = 500
      }
    }
  }
}
