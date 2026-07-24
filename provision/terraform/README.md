# Terraform provisioning

Provisions OpenLMIS eLMIS-RDC environments on AWS: an application host, an
optional RDS PostgreSQL database and a load-balancer pair terminating TLS.

## Layout

- `modules/openlmis-server/` - EC2 app host (Ubuntu 24.04, Docker + Compose via
  user data, Elastic IP for outbound) and an optional RDS PostgreSQL instance
- `modules/openlmis-lb/` - NLB (stable public EIP, SSH/Docker-TLS passthrough)
  in front of an internal ALB terminating TLS with an ACM certificate, with
  optional Superset exposure and optional second-AZ subnet creation for
  single-AZ VPCs
- `dev/` - the dev environment; the reference example of wiring both modules

All environment-specific values live in a single tfvars file kept in the
private `rdc-configuration` repo (`<env>_env/terraform.tfvars`) - the
Terraform equivalent of `settings.env`. The `.tf` files in the environment
directory are wiring only and normally never change.

## Traffic architecture

```
DNS A record -> NLB (public EIP)
                 22, 2376  -> instance (SSH, Docker TLS; admin_cidrs enforced
                              on the instance SG via client IP preservation)
                 80, 443   -> internal ALB -> ACM TLS, HTTP->HTTPS redirect
                              -> instance:80 (nginx)
                 8443      -> internal ALB -> ACM TLS -> instance:8088
                              (Superset; only when superset_enabled)
```

- The instance keeps its own Elastic IP for outbound traffic (docker pulls,
  promtail, database access) - external allowlists (e.g. Loki 3100 on the
  monitoring server) must reference this `public_ip` output, not the NLB IP.
- `admin_cidrs` must include the VPC CIDR (NLB health checks) and the Jenkins
  egress IP, besides the operators' addresses.
- Superset's plain-HTTP 8088 is only reachable from the ALB security group;
  nothing else is exposed. Other reporting services (Airflow, Kafka UI,
  ClickHouse) stay host-internal - use an SSH tunnel.

## Database (optional, `create_db`)

- **Subnets**: create a subnet group from `db_subnet_ids` (needs two AZs), or
  reuse an existing one via `db_subnet_group_name`, optionally in another VPC
  (`db_vpc_id`) with `db_publicly_accessible = true` when VPC peering is not
  possible (the DB security group then admits the app host's EIP and
  `admin_cidrs` only).
- **Parameters**: reuse an existing group via `db_parameter_group_name`, or let
  the module create a CDC-tuned one: `rds.logical_replication=1`, 10
  replication slots/WAL senders, `max_slot_wal_keep_size=4GB` (Debezium CDC for
  the reporting stack) and `password_encryption=md5` (OpenLMIS services cannot
  authenticate with scram-sha-256). A publicly accessible instance should force
  SSL (`rds.force_ssl=1`).
- **Contents**: start empty, or restore from a snapshot via
  `db_snapshot_identifier` - master username and data come from the snapshot,
  the password is reset to `db_password`, and `db_allocated_storage` must be at
  least the snapshot size.

## Usage (existing environment)

```bash
AWS_PROFILE=<profile> terraform -chdir=/<abs path>/rdc-deployment/provision/terraform/dev init
AWS_PROFILE=<profile> terraform -chdir=/<abs path>/rdc-deployment/provision/terraform/dev plan \
  -var-file=/<abs path>/rdc-configuration/dev_env/terraform.tfvars
AWS_PROFILE=<profile> terraform -chdir=/<abs path>/rdc-deployment/provision/terraform/dev apply \
  -var-file=/<abs path>/rdc-configuration/dev_env/terraform.tfvars
```

Verify the account with `aws sts get-caller-identity` before applying. Note
that changing `user_data` stops and starts the instance.

State is kept local (single operator); `terraform.tfstate` is gitignored,
contains the DB password, and must not be committed or deleted. For remote
state see the commented `backend "s3"` block in `dev/main.tf`.

## Creating a new environment

1. Verify prerequisites in the target account: a VPC subnet with a default
   route to an internet gateway, an ISSUED ACM certificate covering the
   environment FQDN, two free Elastic IPs in the region.
2. Copy `dev/` to `<env>/`; the only edits normally needed are the backend
   block and the `alb_sg_description` override (dev-only legacy value - remove
   it for new environments).
3. Create `<env>_env/terraform.tfvars` in `rdc-configuration` from
   `dev/terraform.tfvars.example` and fill in all values.
4. `init`, `plan`, `apply` as above.

## Post-apply steps

1. Create the DNS A record for the environment FQDN pointing at the `nlb_ip`
   output.
2. Put the `private_ip` output into the environment's `env.conf` in
   `rdc-configuration`, then generate and install Docker TLS certs following
   the `rdc-configuration` README (`./generate_certs.sh <env>_env`,
   `./upload_certs.sh <env>_env <ssh-key>`, then the dockerd systemd override
   on the server).
3. Allow the instance's `public_ip` output on external systems that receive
   traffic from it (e.g. Loki 3100 on the monitoring server).
4. If the module created a new parameter group (or the instance was restored
   from a snapshot), reboot the RDS instance once so static parameters such as
   `rds.logical_replication` take effect.
5. With SSL forced on the database, keep `sslmode` in the `DATABASE_URL` in
   `settings.env` and `SOURCE_PG_SSLMODE=require` in `.env.reporting-stack`.
6. For the reporting stack and Superset embedding prerequisites, see
   `dev/reporting-stack/README.md`.
