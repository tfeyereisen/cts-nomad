job "consul-ingress-sync-${region}" {
  datacenters = ["dc1"]

  group "sync" {
    count = "1"

      restart {
        interval = "5m"
        attempts = 4
        delay    = "60s"
        mode     = "delay"
      }

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

      template {
        data = <<-EOF
                ${sync_config}
                EOF
        destination = "local/sync.hcl"
      }

      template {
        data = <<-EOF
                ${sync_module_main}
                EOF
        destination = "local/sync-module/main.tf"
      }
      template {
        data = <<-EOF
                ${sync_module_variables}
                EOF
        destination = "local/sync-module/variables.tf"
      }
      template {
        data = <<-EOF
                ${service_routes_main}
                EOF
        destination = "local/sync-module/service-routes/main.tf"
      }
      template {
        data = <<-EOF
                ${service_routes_variables}
                EOF
        destination = "local/sync-module/service-routes/variables.tf"
      }

      resources {
        cpu = 800
        memory = 2000
      }
    }
  }
}
