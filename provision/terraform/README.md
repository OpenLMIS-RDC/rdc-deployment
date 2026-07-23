# Terraform provisioning

Provisions OpenLMIS eLMIS-RDC servers on AWS. Written fresh for the dev
environment; the legacy `openlmis-deployment/provision/terraform` module (Core) was
used only as a requirements reference - it targets Terraform 0.11, a 2017 AMI and
another AWS account, and is not reusable.

## Layout

- `modules/openlmis-server/` - reusable module: EC2 app host (Ubuntu 24.04, Docker +
  Compose via user data, Elastic IP) and an optional RDS PostgreSQL instance
- `dev/` - the dev environment (`elmis-dev`)

## What the module sets up

### App host

Latest Ubuntu 24.04 AMI, gp3 encrypted root volume (100 GB default), swap file,
Docker Engine + Compose plugin installed on first boot. Instance type is
configurable (`instance_type`, dev default `r5.xlarge`, 32 GB RAM) - sized for
OpenLMIS with the reporting dev profile (`docker-compose.reporting-dev.yml`) plus
the CDC reporting stack; bump it if the full service set is needed.

SSH access: either reference an existing EC2 key pair (`ssh_key_name`) or have
Terraform create one from a locally generated public key (`ssh_public_key`) - the
private key then never leaves your machine.

### Security groups

- 80/443 open to `http_cidrs` (default: public); the dev environment opens the
  Superset ports 8088/8443 the same way (`reporting_ports`).
- 22 (SSH) and 2376 (Docker TLS) restricted to `admin_cidrs`; `extra_tcp_ports`
  adds more admin-only ports. Other reporting services (Airflow, Kafka UI,
  ClickHouse) stay host-internal unless opened this way.
- Database: 5432 admitted from the app security group when the DB shares the app
  VPC, or from the app host's Elastic IP when it lives in a different VPC; with a
  public endpoint, `admin_cidrs` are admitted too. Nothing else.

### Database (optional, `create_db`)

RDS PostgreSQL (version and instance class configurable). Placement is flexible:

- **Subnets**: create a subnet group from `db_subnet_ids` (needs two AZs), or reuse
  an existing one via `db_subnet_group_name`, optionally in another VPC
  (`db_vpc_id`) with `db_publicly_accessible = true` when VPC peering is not
  possible.
- **Parameters**: reuse an existing group via `db_parameter_group_name`, or let the
  module create a CDC-tuned one: `rds.logical_replication=1`, 10 replication
  slots/WAL senders, `max_slot_wal_keep_size=4GB` (Debezium CDC for the reporting
  stack) and `password_encryption=md5` (OpenLMIS services cannot authenticate with
  scram-sha-256). A publicly accessible instance should force SSL
  (`rds.force_ssl=1`).
- **Contents**: start empty, or restore from a snapshot via
  `db_snapshot_identifier` - the master username and all data then come from the
  snapshot, the password is reset to `db_password`, and `db_allocated_storage`
  must be at least the snapshot size.

Set `create_db = false` to skip all database resources and run PostgreSQL in a
container on the app host instead.

## Usage (dev)

Real variable values, including DB credentials, live in the private
`rdc-configuration` repo (`dev_env/terraform.tfvars`). Do not commit them here.
The AWS region is configurable via the `region` variable (default `eu-west-1`).

```bash
cd dev
terraform init
terraform plan  -var-file=../../../../rdc-configuration/dev_env/terraform.tfvars
terraform apply -var-file=../../../../rdc-configuration/dev_env/terraform.tfvars
```

Use `AWS_PROFILE=<profile>` (or equivalent credentials) for the target account and
verify with `aws sts get-caller-identity` before applying.

State is kept local for the time being - a deliberate choice for a single
operator. The local `terraform.tfstate` must not be committed or deleted (it is
gitignored and contains the DB password). If shared or remote state is ever
needed, see the commented `backend "s3"` block in `dev/main.tf`.

## Post-apply steps

1. Create a DNS A record for the environment FQDN pointing at the `public_ip`
   output.
2. Put the `private_ip` output into the environment's `env.conf` in
   `rdc-configuration`.
3. Generate and install Docker TLS certs following the `rdc-configuration` README
   (`./generate_certs.sh <env>`, `./upload_certs.sh <env> <ssh-key>`, then the
   systemd override on the server).
4. If the module created a new parameter group (or the instance was restored from
   a snapshot), reboot the RDS instance once so static parameters such as
   `rds.logical_replication` take effect.
5. When SSL is forced on the database, append `?sslmode=require` to the
   `DATABASE_URL` in `settings.env` and set `SOURCE_PG_SSLMODE=require` for the
   reporting stack.
