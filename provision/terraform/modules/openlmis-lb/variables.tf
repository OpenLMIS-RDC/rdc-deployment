variable "name" {
  description = "Environment name, used as a prefix for all resources (e.g. elmis-dev)"
  type        = string
}

variable "vpc_id" {
  description = "VPC of the application host"
  type        = string
}

variable "subnet_id" {
  description = "Subnet of the application host; also carries the NLB and the ALB's first leg"
  type        = string
}

variable "alb_second_subnet_id" {
  description = "Existing subnet in a second AZ for the ALB; leave empty to create one from vpc_secondary_cidr/lb_subnet_cidr (for VPCs with all subnets in one AZ)"
  type        = string
  default     = ""
}

variable "vpc_secondary_cidr" {
  description = "Secondary CIDR added to the VPC when creating the second-AZ subnet; must be outside 10.0.0.0/15 when the primary CIDR is inside it"
  type        = string
  default     = ""
}

variable "lb_subnet_cidr" {
  description = "CIDR of the created second-AZ subnet"
  type        = string
  default     = ""
}

variable "lb_subnet_az" {
  description = "Availability zone of the created second-AZ subnet"
  type        = string
  default     = ""
}

variable "certificate_domain" {
  description = "Domain of an issued ACM certificate used for TLS termination (e.g. a wildcard cert's base domain)"
  type        = string
}

variable "instance_id" {
  description = "Application host instance targeted by the load balancers"
  type        = string
}

variable "alb_sg_description" {
  description = "Description of the ALB security group (changing it forces SG replacement)"
  type        = string
  default     = "HTTP/HTTPS to the ALB (client IPs preserved by the NLB)"
}

variable "public_cidrs" {
  description = "CIDRs allowed to reach the public listeners"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "superset_enabled" {
  description = "Expose Superset: NLB listener superset_listener_port -> ALB TLS -> instance superset_target_port"
  type        = bool
  default     = false
}

variable "superset_listener_port" {
  description = "Public TLS port for Superset"
  type        = number
  default     = 8443
}

variable "superset_target_port" {
  description = "Superset's plain-HTTP port on the instance"
  type        = number
  default     = 8088
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default     = {}
}
