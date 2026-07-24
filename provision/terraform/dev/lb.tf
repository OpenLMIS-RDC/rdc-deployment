# TLS termination:
# DNS (A record) -> NLB holding the environment's public EIP. The NLB passes
# 22/2376 straight to the instance and forwards 80/443 to an internal ALB,
# which terminates TLS with an ACM certificate and redirects HTTP to HTTPS.
# The ALB needs two AZs; the VPC only has subnets in one, so a secondary
# CIDR and a second-AZ subnet are added. The instance has its own EIP for
# outbound traffic (also used by the DB security group rule).

# AWS restricts secondary CIDRs from 10.0.0.0/15 when the primary is in that
# range, hence 10.2.x rather than 10.0.1.x.
resource "aws_vpc_ipv4_cidr_block_association" "lb" {
  vpc_id     = var.vpc_id
  cidr_block = "10.2.0.0/24"
}

resource "aws_subnet" "lb" {
  vpc_id            = var.vpc_id
  cidr_block        = "10.2.0.0/25"
  availability_zone = "${var.region}b"

  tags = {
    Name      = "elmis-dev-lb"
    ManagedBy = "terraform"
  }

  depends_on = [aws_vpc_ipv4_cidr_block_association.lb]
}

# Public entry IP of the environment (the DNS A record target).
resource "aws_eip" "nlb" {
  domain = "vpc"

  tags = {
    Name      = "elmis-dev-nlb"
    ManagedBy = "terraform"
  }
}

# --- NLB: stable entry point on the public EIP ---

resource "aws_lb" "nlb" {
  name               = "elmis-dev-nlb"
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = var.subnet_id
    allocation_id = aws_eip.nlb.id
  }

  tags = {
    Environment = "dev"
    Project     = "eLMIS-RDC"
    ManagedBy   = "terraform"
  }
}

resource "aws_lb_target_group" "ssh" {
  name        = "elmis-dev-ssh"
  port        = 22
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"
}

resource "aws_lb_target_group" "docker_tls" {
  name        = "elmis-dev-docker-tls"
  port        = 2376
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"
}

resource "aws_lb_target_group" "alb_http" {
  name        = "elmis-dev-alb-http"
  port        = 80
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "alb"
}

resource "aws_lb_target_group" "alb_https" {
  name        = "elmis-dev-alb-https"
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

resource "aws_lb_target_group_attachment" "ssh" {
  target_group_arn = aws_lb_target_group.ssh.arn
  target_id        = module.dev.instance_id
  port             = 22
}

resource "aws_lb_target_group_attachment" "docker_tls" {
  target_group_arn = aws_lb_target_group.docker_tls.arn
  target_id        = module.dev.instance_id
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

# --- ALB: TLS termination and HTTP->HTTPS redirect ---

resource "aws_security_group" "alb" {
  name        = "elmis-dev-alb"
  description = "HTTP/HTTPS to the dev ALB (client IPs preserved by the NLB)"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "elmis-dev-alb"
    ManagedBy = "terraform"
  }
}

data "aws_acm_certificate" "wildcard" {
  domain      = "logimev.cd"
  statuses    = ["ISSUED"]
  most_recent = true
}

resource "aws_lb" "app" {
  name               = "elmis-dev-alb"
  load_balancer_type = "application"
  internal           = true
  security_groups    = [aws_security_group.alb.id]
  subnets            = [var.subnet_id, aws_subnet.lb.id]

  tags = {
    Environment = "dev"
    Project     = "eLMIS-RDC"
    ManagedBy   = "terraform"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "elmis-dev-http"
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
  target_id        = module.dev.instance_id
  port             = 80
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.wildcard.arn

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
