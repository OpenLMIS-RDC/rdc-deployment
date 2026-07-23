terraform {
  required_version = ">= 1.5.0"

  # State is kept local for the time being (single operator). If remote,
  # shared state is ever needed (CI, more operators), create a versioned
  # and encrypted S3 bucket, uncomment, and run: terraform init -migrate-state
  # backend "s3" {
  #   bucket  = "<state-bucket>"
  #   key     = "elmis-dev.tfstate"
  #   region  = "eu-west-1"
  #   encrypt = true
  # }
}

provider "aws" {
  region = var.region
}

module "dev" {
  source = "../modules/openlmis-server"

  name           = "elmis-dev"
  vpc_id         = var.vpc_id
  subnet_id      = var.subnet_id
  ssh_key_name   = var.ssh_key_name
  ssh_public_key = var.ssh_public_key
  instance_type  = var.instance_type
  admin_cidrs    = var.admin_cidrs

  extra_public_tcp_ports = var.reporting_ports
  monitoring_cidrs       = var.monitoring_cidrs

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

  tags = {
    Environment = "dev"
    Project     = "eLMIS-RDC"
    ManagedBy   = "terraform"
  }
}
