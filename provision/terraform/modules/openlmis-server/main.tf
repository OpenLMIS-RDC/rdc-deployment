data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "OpenLMIS application host - ${var.name}"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.http_cidrs
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.http_cidrs
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  ingress {
    description = "Docker TLS"
    from_port   = 2376
    to_port     = 2376
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }

  dynamic "ingress" {
    for_each = toset(var.extra_tcp_ports)
    content {
      description = "Extra admin port ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.admin_cidrs
    }
  }

  dynamic "ingress" {
    for_each = toset(var.extra_public_tcp_ports)
    content {
      description = "Extra public port ${ingress.value}"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.http_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-app" })
}

resource "aws_key_pair" "app" {
  count = var.ssh_public_key != "" ? 1 : 0

  key_name   = "${var.name}-key"
  public_key = var.ssh_public_key
  tags       = var.tags
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.ssh_public_key != "" ? aws_key_pair.app[0].key_name : var.ssh_key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.app.id]

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    swap_gb = var.swap_gb
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    delete_on_termination = true
    encrypted             = true
  }

  tags        = merge(var.tags, { Name = "${var.name}-app" })
  volume_tags = merge(var.tags, { Name = "${var.name}-app" })

  lifecycle {
    ignore_changes = [ami]

    precondition {
      condition     = (var.ssh_key_name != "") != (var.ssh_public_key != "")
      error_message = "Set exactly one of ssh_key_name (existing key pair) or ssh_public_key (creates a new key pair)."
    }
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = merge(var.tags, { Name = "${var.name}-app" })
}

locals {
  db_vpc_id    = var.db_vpc_id != "" ? var.db_vpc_id : var.vpc_id
  db_cross_vpc = local.db_vpc_id != var.vpc_id
}

resource "aws_security_group" "db" {
  count = var.create_db ? 1 : 0

  name        = "${var.name}-db"
  description = "OpenLMIS database - ${var.name}"
  vpc_id      = local.db_vpc_id

  # Same VPC: admit the app SG by reference. Cross-VPC (no peering):
  # the app host reaches the public endpoint from its Elastic IP.
  dynamic "ingress" {
    for_each = local.db_cross_vpc ? [] : [1]
    content {
      description     = "PostgreSQL from app host"
      from_port       = 5432
      to_port         = 5432
      protocol        = "tcp"
      security_groups = [aws_security_group.app.id]
    }
  }

  dynamic "ingress" {
    for_each = local.db_cross_vpc ? [1] : []
    content {
      description = "PostgreSQL from app host EIP"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = ["${aws_eip.app.public_ip}/32"]
    }
  }

  dynamic "ingress" {
    for_each = var.db_publicly_accessible ? [1] : []
    content {
      description = "PostgreSQL from admin CIDRs"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = var.admin_cidrs
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_db_subnet_group" "db" {
  count = var.create_db && var.db_subnet_group_name == "" ? 1 : 0

  name       = "${var.name}-db"
  subnet_ids = var.db_subnet_ids
  tags       = var.tags
}

resource "aws_db_parameter_group" "db" {
  count = var.create_db && var.db_parameter_group_name == "" ? 1 : 0

  name   = "${var.name}-postgres${var.db_engine_version}"
  family = "postgres${var.db_engine_version}"

  # Debezium CDC for the reporting stack requires logical replication.
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_replication_slots"
    value        = "10"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_wal_senders"
    value        = "10"
    apply_method = "pending-reboot"
  }

  # Caps WAL retention if the reporting stack stops consuming (MB).
  parameter {
    name  = "max_slot_wal_keep_size"
    value = "4096"
  }

  # OpenLMIS services fail to authenticate against scram-sha-256.
  parameter {
    name  = "password_encryption"
    value = "md5"
  }

  tags = var.tags
}

resource "aws_db_instance" "db" {
  count = var.create_db ? 1 : 0

  identifier                 = "${var.name}-db"
  engine                     = "postgres"
  engine_version             = var.db_engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.db_instance_class
  allocated_storage          = var.db_allocated_storage
  storage_type               = "gp3"
  storage_encrypted          = var.db_storage_encrypted

  snapshot_identifier = var.db_snapshot_identifier != "" ? var.db_snapshot_identifier : null

  db_name  = var.db_snapshot_identifier != "" ? null : var.db_name
  username = var.db_snapshot_identifier != "" ? null : var.db_username
  password = var.db_password

  db_subnet_group_name   = var.db_subnet_group_name != "" ? var.db_subnet_group_name : aws_db_subnet_group.db[0].name
  parameter_group_name   = var.db_parameter_group_name != "" ? var.db_parameter_group_name : aws_db_parameter_group.db[0].name
  vpc_security_group_ids = [aws_security_group.db[0].id]
  publicly_accessible    = var.db_publicly_accessible

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    precondition {
      condition     = (var.db_username != "" || var.db_snapshot_identifier != "") && var.db_password != "" && (var.db_subnet_group_name != "" || length(var.db_subnet_ids) >= 2)
      error_message = "create_db is true: set db_password, db_username (unless restoring from a snapshot) and either db_subnet_group_name or at least two db_subnet_ids."
    }
  }
}
