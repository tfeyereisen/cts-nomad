
module "sync-lb" {
    source = "./modules/load-balancer"
    region = var.region
    subnet_ids = [data.aws_subnet.subnet_a.id, data.aws_subnet.subnet_b.id, data.aws_subnet.subnet_c.id]
    security_group_id = aws_security_group.alb_sg.id
    certificate_arn = aws_acm_certificate.cert.arn
    zone_id = var.zone_id
    domain = var.domain
}