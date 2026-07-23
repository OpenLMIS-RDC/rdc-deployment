variable "name" {
  description = "Environment name, used as a prefix for all resources (e.g. elmis-dev)"
  type        = string
}

variable "vpc_id" {
  description = "ID of the existing VPC to deploy into"
  type        = string
}

variable "subnet_id" {
  description = "Public subnet for the application instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for the application host"
  type        = string
  default     = "r5.xlarge"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair; leave empty when ssh_public_key is set"
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "SSH public key material; when set, a new EC2 key pair is created (generate locally with ssh-keygen, the private key never leaves your machine)"
  type        = string
  default     = ""
}

variable "swap_gb" {
  description = "Swap file size in GB created on first boot"
  type        = number
  default     = 8
}

variable "admin_cidrs" {
  description = "CIDR blocks allowed to reach SSH (22) and Docker TLS (2376)"
  type        = list(string)
}

variable "http_cidrs" {
  description = "CIDR blocks allowed to reach HTTP/HTTPS"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "extra_tcp_ports" {
  description = "Additional TCP ports opened to admin_cidrs"
  type        = list(number)
  default     = []
}

variable "extra_public_tcp_ports" {
  description = "Additional TCP ports opened to http_cidrs (e.g. Superset 8088/8443)"
  type        = list(number)
  default     = []
}

variable "create_db" {
  description = "Whether to create an RDS PostgreSQL instance"
  type        = bool
  default     = true
}

variable "db_vpc_id" {
  description = "VPC for the RDS instance; defaults to vpc_id. When different, the app host reaches the DB over its public endpoint (the DB security group admits the app EIP)"
  type        = string
  default     = ""
}

variable "db_subnet_group_name" {
  description = "Name of an existing DB subnet group to use; when empty, one is created from db_subnet_ids"
  type        = string
  default     = ""
}

variable "db_subnet_ids" {
  description = "Subnets for the RDS subnet group (at least two AZs); required when db_subnet_group_name is empty"
  type        = list(string)
  default     = []
}

variable "db_publicly_accessible" {
  description = "Give the RDS instance a public endpoint (access still limited by security group)"
  type        = bool
  default     = false
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "14"
}

variable "db_allocated_storage" {
  description = "RDS storage in GB"
  type        = number
  default     = 50
}

variable "db_storage_encrypted" {
  description = "Encrypt RDS storage; must match the snapshot's encryption when restoring (an unencrypted snapshot restores to an unencrypted instance)"
  type        = bool
  default     = true
}

variable "db_parameter_group_name" {
  description = "Name of an existing DB parameter group to use; when empty, a CDC-tuned group (logical replication, md5) is created"
  type        = string
  default     = ""
}

variable "db_snapshot_identifier" {
  description = "DB snapshot to restore the instance from; the master username and databases come from the snapshot, the password is reset to db_password"
  type        = string
  default     = ""
}

variable "db_name" {
  description = "Initial database name (ignored when restoring from a snapshot)"
  type        = string
  default     = "open_lmis"
}

variable "db_username" {
  description = "Master username for the RDS instance; required when create_db is true"
  type        = string
  sensitive   = true
  default     = ""
}

variable "db_password" {
  description = "Master password for the RDS instance; required when create_db is true"
  type        = string
  sensitive   = true
  default     = ""
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
