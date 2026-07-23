variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "vpc_id" {
  description = "ID of the existing VPC to deploy the application host into"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet for the application instance"
  type        = string
}

variable "db_vpc_id" {
  description = "VPC for the RDS instance; defaults to vpc_id"
  type        = string
  default     = ""
}

variable "db_subnet_group_name" {
  description = "Existing DB subnet group to use; leave empty to create one from db_subnet_ids"
  type        = string
  default     = ""
}

variable "db_subnet_ids" {
  description = "Subnets for the RDS subnet group (at least two AZs); required when db_subnet_group_name is empty"
  type        = list(string)
  default     = []
}

variable "db_publicly_accessible" {
  description = "Give the RDS instance a public endpoint"
  type        = bool
  default     = false
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair name; leave empty when ssh_public_key is set"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key material; when set, a new key pair is created"
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the application host"
  type        = string
  default     = "r5.xlarge"
}

variable "create_db" {
  description = "Whether to create the RDS instance; set false to run the database in a container instead"
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_parameter_group_name" {
  description = "Existing DB parameter group to use; leave empty to create the CDC-tuned one"
  type        = string
  default     = ""
}

variable "db_snapshot_identifier" {
  description = "DB snapshot to restore from; leave empty for a fresh database"
  type        = string
  default     = ""
}

variable "db_allocated_storage" {
  description = "RDS storage in GB; must be at least the snapshot size when restoring"
  type        = number
  default     = 50
}

variable "db_storage_encrypted" {
  description = "Encrypt RDS storage; must match the snapshot's encryption when restoring"
  type        = bool
  default     = true
}

variable "admin_cidrs" {
  description = "CIDRs allowed on SSH and Docker TLS"
  type        = list(string)
}

variable "reporting_ports" {
  description = "Reporting stack ports opened publicly like 80/443: Superset HTTP (8088) and HTTPS (8443)"
  type        = list(number)
  default     = [8088, 8443]
}

variable "db_username" {
  description = "Required when create_db is true"
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_password" {
  description = "Required when create_db is true"
  type        = string
  sensitive   = true
  default     = ""
}
