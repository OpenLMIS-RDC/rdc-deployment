# TLS termination:
# DNS (A record) -> NLB holding the environment's public EIP. The NLB passes
# 22/2376 straight to the instance and forwards 80/443 to an internal ALB,
# which terminates TLS with an ACM certificate and redirects HTTP to HTTPS.
# The ALB needs two AZs; when the VPC has subnets in only one, set
# vpc_secondary_cidr/lb_subnet_cidr/lb_subnet_az to create the second leg,
# otherwise pass an existing subnet via alb_second_subnet_id.

locals {
  create_subnet  = var.alb_second_subnet_id == ""
  alb_second_leg = local.create_subnet ? aws_subnet.lb[0].id : var.alb_second_subnet_id
}

resource "aws_vpc_ipv4_cidr_block_association" "lb" {
  count = local.create_subnet ? 1 : 0

  vpc_id     = var.vpc_id
  cidr_block = var.vpc_secondary_cidr
}

resource "aws_subnet" "lb" {
  count = local.create_subnet ? 1 : 0

  vpc_id            = var.vpc_id
  cidr_block        = var.lb_subnet_cidr
  availability_zone = var.lb_subnet_az

  tags = merge(var.tags, { Name = "${var.name}-lb" })

  depends_on = [aws_vpc_ipv4_cidr_block_association.lb]
}

# Public entry IP of the environment (the DNS A record target).
resource "aws_eip" "nlb" {
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nlb" })
}

# --- NLB: stable entry point on the public EIP ---

resource "aws_lb" "nlb" {
  name               = "${var.name}-nlb"
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = var.subnet_id
    allocation_id = aws_eip.nlb.id
  }

  tags = var.tags
}

resource "aws_lb_target_group" "ssh" {
  name        = "${var.name}-ssh"
  port        = 22
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"
}

resource "aws_lb_target_group" "docker_tls" {
  name        = "${var.name}-docker-tls"
  port        = 2376
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"
}

resource "aws_lb_target_group" "alb_http" {
  name        = "${var.name}-alb-http"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "alb"
}

resource "aws_lb_target_group" "alb_https" {
  name        = "${var.name}-alb-https"
  port        = 443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "alb"

  # the ALB serves TLS on 443, so a plain-HTTP health check cannot connect
  health_check {
    protocol = "HTTPS"
    path     = "/"
  }
}

resource "aws_lb_target_group" "alb_superset" {
  count = var.superset_enabled ? 1 : 0

  name        = "${var.name}-alb-superset"
  port        = var.superset_listener_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "alb"

  health_check {
    protocol = "HTTPS"
    path     = "/health"
  }
}

resource "aws_lb_target_group_attachment" "ssh" {
  target_group_arn = aws_lb_target_group.ssh.arn
  target_id        = var.instance_id
  port             = 22
}

resource "aws_lb_target_group_attachment" "docker_tls" {
  target_group_arn = aws_lb_target_group.docker_tls.arn
  target_id        = var.instance_id
  port             = 2376
}

resource "aws_lb_target_group_attachment" "alb_http" {
  target_group_arn = aws_lb_target_group.alb_http.arn
  target_id        = aws_lb.app.arn
  port             = 80

  depends_on = [aws_lb_listener.http]
}

resource "aws_lb_target_group_attachment" "alb_https" {
  target_group_arn = aws_lb_target_group.alb_https.arn
  target_id        = aws_lb.app.arn
  port             = 443

  depends_on = [aws_lb_listener.https]
}

resource "aws_lb_target_group_attachment" "alb_superset" {
  count = var.superset_enabled ? 1 : 0

  target_group_arn = aws_lb_target_group.alb_superset[0].arn
  target_id        = aws_lb.app.arn
  port             = var.superset_listener_port

  depends_on = [aws_lb_listener.superset]
}

resource "aws_lb_listener" "nlb_ssh" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 22
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ssh.arn
  }
}

resource "aws_lb_listener" "nlb_docker_tls" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 2376
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.docker_tls.arn
  }
}

resource "aws_lb_listener" "nlb_http" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_http.arn
  }
}

resource "aws_lb_listener" "nlb_https" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_https.arn
  }
}

resource "aws_lb_listener" "nlb_superset" {
  count = var.superset_enabled ? 1 : 0

  load_balancer_arn = aws_lb.nlb.arn
  port              = var.superset_listener_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_superset[0].arn
  }
}

# --- ALB: TLS termination and HTTP->HTTPS redirect ---

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = var.alb_sg_description
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.public_cidrs
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.public_cidrs
  }

  dynamic "ingress" {
    for_each = var.superset_enabled ? [1] : []
    content {
      description = "Superset HTTPS"
      from_port   = var.superset_listener_port
      to_port     = var.superset_listener_port
      protocol    = "tcp"
      cidr_blocks = var.public_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-alb" })
}

data "aws_acm_certificate" "this" {
  domain      = var.certificate_domain
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_lb" "app" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.alb.id]
  subnets            = [var.subnet_id, local.alb_second_leg]

  tags = var.tags
}

resource "aws_lb_target_group" "app" {
  name     = "${var.name}-http"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  # nginx answers 307 (https redirect) to plain-HTTP health checks
  health_check {
    path    = "/"
    matcher = "200-399"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = var.instance_id
  port             = 80
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.this.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# --- Superset: TLS on superset_listener_port, forwarded to the container ---

resource "aws_lb_target_group" "superset" {
  count = var.superset_enabled ? 1 : 0

  name     = "${var.name}-superset"
  port     = var.superset_target_port
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path    = "/health"
    matcher = "200-399"
  }
}

resource "aws_lb_target_group_attachment" "superset" {
  count = var.superset_enabled ? 1 : 0

  target_group_arn = aws_lb_target_group.superset[0].arn
  target_id        = var.instance_id
  port             = var.superset_target_port
}

resource "aws_lb_listener" "superset" {
  count = var.superset_enabled ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = var.superset_listener_port
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.this.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.superset[0].arn
  }
}

