
# Find distinct service name/environment combinations
#
# e.g. the result might be:
#     ["backend-test1", "backend-test2", "service-test1"]
locals {
  service_name_environments = { for i in distinct(flatten([
    for v in var.services : [{
      service     = v.name
      environment = v.meta.environment
      subdomain   = lookup(v.meta, "subdomain", "")
    }]
  ])) : trimprefix(join("-", [i.subdomain, i.service, i.environment]), "-") => i }
}

# Create new service map for each service name/environment
#
# The output of this is a map where the top level key is the servicename-environment that corresponds
# to the services variable data structure of this, and the service-routes module. We are refactoring the incoming
# services into separate subsets of services for each service/environment while maintaining the data structure
locals {
  service_collection = { for key, v in local.service_name_environments :
    key => { for v2 in var.services :
      v2.id => v2 if(v2.meta.environment == v.environment && v2.name == v.service && lookup(v2.meta, "subdomain", "") == v.subdomain)
    }
  }
}

module "service-routes" {
  for_each                                = local.service_collection
  source                                  = "./service-routes"
  services                                = each.value
  zone_id = var.zone_id
  domain = var.domain
}

# For debugging
resource "local_file" "service_map" {
  filename = "service_map.json"
  content  = jsonencode(local.service_collection)
}