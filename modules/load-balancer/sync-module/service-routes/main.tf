provider "aws" {
  alias = "target-account"
}

provider "aws" {
  alias = "shared-account"
}

# Create a list of distinct versions
locals {
  example_service = element(values(var.services), 0)
  versions        = distinct([for i in values(var.services) : lookup(i.meta, "version", "none")])
}

# Construct hostname and infer service name and environment
#
# If environment is prod, then hostname = service_name.exactsciences.net
# If environment is not prod, then hostname = service_name-environment.exactsciences.net
#
# If the service meta contains the subdomain key, then prepend the subdomain to the hostname:
#     subdomain = api   results in     api.service_name.exactsciences.net for prod
#                                      api.service_name-environment.exactsciences.net for non prod
locals {
  service_name = local.example_service.name
  environment  = local.example_service.meta.environment
  subdomain    = lookup(local.example_service.meta, "subdomain", "")
  hostname = join("", [
    local.subdomain == "" ? "" : join("", [local.subdomain, "."]),
    length(regexall("(.*)prod(.*)", lower(local.environment))) > 0 ? local.example_service.meta.hostname : "${local.example_service.meta.hostname}-${local.environment}",
    ".exactsciences.net"
  ])
  rule_name                           = trimprefix("${local.subdomain}-${local.service_name}-${local.environment}", "-")
  health_check_path                   = lookup(local.example_service.meta, "health_check_path", "/")
  health_check_healthy_response_codes = lookup(local.example_service.meta, "health_check_healthy_response_codes", "200")
}

data "aws_vpc" "default" {
  provider = aws.target-account
  filter {
    name   = "tag:Default"
    values = ["Yes"]
  }
}

# This is the DEFAULT load balancer. All nomad jobs listen through this laod balancer
data "aws_alb" "default" {
  provider = aws.target-account
  name     = "consul-ingress-alb"
}

# The load balancer has a listener on 443
data "aws_lb_listener" "selected443" {
  provider          = aws.target-account
  load_balancer_arn = data.aws_alb.default.arn
  port              = 443
}

# Create a target group for all versions of the service
resource "aws_lb_target_group" "service-tg" {
  provider    = aws.target-account
  name        = "${replace(substr(local.hostname, 0, 28), ".", "-")}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id
  health_check {
    path    = local.health_check_path
    matcher = local.health_check_healthy_response_codes
  }
}

# Create a target group attachment for all versions IP:port
resource "aws_lb_target_group_attachment" "test" {
  provider         = aws.target-account
  for_each         = var.services
  target_group_arn = aws_lb_target_group.service-tg.arn
  target_id        = each.value.node_address
  port             = each.value.port
}

# Create a target group for each version of the service
resource "aws_lb_target_group" "service-version-tg" {
  provider    = aws.target-account
  for_each    = toset(local.versions)
  name        = "${substr(local.rule_name, 0, 28 - length(local.rule_name))}-${replace(each.value, ".", "-")}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.default.id
  health_check {
    path    = local.health_check_path
    matcher = local.health_check_healthy_response_codes
  }
}

# Create a target group attachment for each version IP:port
resource "aws_lb_target_group_attachment" "versions" {
  provider         = aws.target-account
  for_each         = var.services
  target_group_arn = aws_lb_target_group.service-version-tg[lookup(each.value.meta, "version", "none")].arn
  target_id        = each.value.node_address
  port             = each.value.port
}

# We need to find a random integer to set the priority for the default service based rule. It doesnt matter what it is,
# we jsut need to be sure that the version specific rules are higher priority then the service default
resource "random_integer" "priority" {
  min = 10
  max = 50000
}

# Here we create the higher priorities for the version specific resources
locals {
  versions_priority = range(random_integer.priority.result - 1, random_integer.priority.result - (length(local.versions) + 1), -1)
}

# This is a host name based forwarding rule for all versions. It must be attached after the version specific ones in
# order for the priority to be created correctly
resource "aws_lb_listener_rule" "service_level" {
  depends_on   = [aws_lb_listener_rule.service_version_rules]
  provider     = aws.target-account
  priority     = random_integer.priority.result
  listener_arn = data.aws_lb_listener.selected443.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service-tg.arn
  }

  condition {
    host_header {
      values = [local.hostname]
    }
  }
}

# This is a host name based forwarding rule to attach to the listener
resource "aws_lb_listener_rule" "service_version_rules" {
  for_each     = toset(local.versions)
  priority     = element(local.versions_priority, index(local.versions, each.value))
  provider     = aws.target-account
  listener_arn = data.aws_lb_listener.selected443.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service-version-tg[each.value].arn
  }

  condition {
    host_header {
      values = [local.hostname]
    }
  }
  condition {
    http_header {
      http_header_name = "x-service-version"
      values           = [each.value]
    }
  }
}

resource "aws_route53_record" "dns_record" {
  provider = aws.shared-account
  zone_id  = "Z1BX3OIJB7B6XS"
  name     = local.hostname
  type     = "CNAME"
  ttl      = "300"
  records  = [data.aws_alb.default.dns_name]
}

resource "aws_acm_certificate" "cert" {
  provider          = aws.target-account
  domain_name       = local.hostname
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "dns_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  provider        = aws.shared-account
  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.exactsciences_net_public_hosted_zone_id
}


data "aws_lb" "consul_ingress_alb" {
  provider = aws.target-account
  name     = "consul-ingress-alb"
}

data "aws_lb_listener" "https_listener" {
  provider          = aws.target-account
  load_balancer_arn = data.aws_lb.consul_ingress_alb.arn
  port              = 443
}

resource "aws_lb_listener_certificate" "listener_cert" {
  provider        = aws.target-account
  listener_arn    = data.aws_lb_listener.https_listener.arn
  certificate_arn = aws_acm_certificate.cert.arn
}