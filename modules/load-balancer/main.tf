
variable "consul_terraform_sync_image" {
  default = "hashicorp/consul-terraform-sync:0.1.0-techpreview2"
}

locals {
  sync_config = templatefile("${path.module}/sync.hcl.tmpl", {
    region = var.region,
    domain = var.domain
  })
  sync_module_main = file("${path.module}/sync-module/main.tf")
  sync_module_variables = templatefile("${path.module}/sync-module/variables.tf.tmpl", {
    region  = var.region,
    zone_id = var.zone_id
    domain  = var.domain
  })
  service_routes_main      = file("${path.module}/sync-module/service-routes/main.tf")
  service_routes_variables = file("${path.module}/sync-module/service-routes/variables.tf")
}

resource "nomad_job" "sync" {
  depends_on = [aws_lb.consul-ingress-alb]
  jobspec = templatefile("${path.module}/sync-job.hcl", {
    region                   = var.region,
    sync_container_image     = var.consul_terraform_sync_image,
    sync_config              = local.sync_config
    sync_module_main         = local.sync_module_main
    sync_module_variables    = local.sync_module_variables
    service_routes_main      = local.service_routes_main
    service_routes_variables = local.service_routes_variables
  })
}