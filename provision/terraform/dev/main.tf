terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket  = "drc-openlmis-terraform-states"
    key     = "elmis-dev.tfstate"
    region  = "eu-west-1"
    encrypt = true
  }
}

provider "aws" {
  region = var.region
}

locals {
  tags = {
    Environment = "dev"
    Project     = "eLMIS-RDC"
    ManagedBy   = "terraform"
  }
}

module "dev" {
  source = "../modules/openlmis-server"

  name           = var.name
  vpc_id         = var.vpc_id
  subnet_id      = var.subnet_id
  ssh_key_name   = var.ssh_key_name
  ssh_public_key = var.ssh_public_key
  instance_type  = var.instance_type
  admin_cidrs    = var.admin_cidrs

  extra_public_tcp_ports = var.reporting_ports
  monitoring_cidrs       = var.monitoring_cidrs

  extra_sg_ingress = var.superset_enabled ? [{
    port                     = 8088
    source_security_group_id = module.lb.alb_security_group_id
    description              = "Superset from the ALB"
  }] : []

  create_db               = var.create_db
  db_vpc_id               = var.db_vpc_id
  db_subnet_group_name    = var.db_subnet_group_name
  db_subnet_ids           = var.db_subnet_ids
  db_instance_class       = var.db_instance_class
  db_parameter_group_name = var.db_parameter_group_name
  db_snapshot_identifier  = var.db_snapshot_identifier
  db_allocated_storage    = var.db_allocated_storage
  db_storage_encrypted    = var.db_storage_encrypted
  db_publicly_accessible  = var.db_publicly_accessible
  db_username             = var.db_username
  db_password             = var.db_password

  tags = local.tags
}

module "lb" {
  source = "../modules/openlmis-lb"

  name               = var.name
  vpc_id             = var.vpc_id
  subnet_id          = var.subnet_id
  certificate_domain = var.certificate_domain
  instance_id        = module.dev.instance_id

  # Matches the pre-module security group; changing it would force replacement.
  alb_sg_description = "HTTP/HTTPS to the dev ALB (client IPs preserved by the NLB)"

  # The VPC has all subnets in one AZ; the ALB's second leg is created from a
  # secondary CIDR (10.0.0.0/15 range is restricted when the primary is in it).
  vpc_secondary_cidr = var.vpc_secondary_cidr
  lb_subnet_cidr     = var.lb_subnet_cidr
  lb_subnet_az       = "${var.region}b"

  superset_enabled = var.superset_enabled

  tags = local.tags
}
