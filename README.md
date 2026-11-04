# LOAD DATA Examples: MySQL INFILE vs Aurora FROM S3

This repository contains copy-pasteable examples for loading CSV data into MySQL using `LOAD DATA LOCAL INFILE` and into Amazon Aurora MySQL using `LOAD DATA FROM S3`.

## The key insight

The syntax is nearly identical. The **only** difference is the source clause on the first line:

| Engine | Source clause |
| --- | --- |
| Plain MySQL | `LOAD DATA LOCAL INFILE '/path/to/file.csv'` |
| Aurora MySQL | `LOAD DATA FROM S3 's3-us-east-1://bucket/key.csv'` |

Everything after that — `INTO TABLE`, `FIELDS TERMINATED BY`, `LINES TERMINATED BY`, `IGNORE 1 LINES`, and the column list — is word for word the same in both.

AWS documents this directly: the [Aurora MySQL Load from S3 guide](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Integrating.LoadFromS3.html) states that `LOAD DATA FROM S3` can load "any text file format that is supported by the MySQL `LOAD DATA INFILE` statement" and mirrors the INFILE parameters one for one. The Aurora docs even point readers to the MySQL LOAD DATA reference for parameter details.

## Why LOCAL INFILE instead of server-side INFILE

Server-side `LOAD DATA INFILE` requires the CSV to sit on the MySQL server's filesystem inside the `secure_file_priv` folder. In a GitLab pipeline that means mounting the file into the service container, which only works on Runners with the Docker socket exposed, privileged mode, or docker-in-docker.

`LOAD DATA LOCAL INFILE` avoids all of that. The **client** (the GitLab job container) reads the CSV from the repo working directory and streams it to the server over the connection. No mounts, no `secure_file_priv` configuration, no special Runner privileges — it works on any Runner that can run Docker containers.

The tradeoff: the entire file travels through the client connection, so it is slower for very large loads. For CI test data that is irrelevant.

## Canonical statement: S3 is the default

The file `sql/load_data.sql` holds the **production statement** — the one you actually run against Aurora. It uses `LOAD DATA FROM S3`. The GitLab pipeline's `sed` one-liner rewrites that single source clause into `LOAD DATA LOCAL INFILE` so the same statement can be tested against a throwaway MySQL container without touching S3.

## Files

- `sql/create_table.sql` — sample table definition
- `sql/sample_customers.csv` — two-row CSV matching the table
- `sql/load_data.sql` — the canonical `LOAD DATA FROM S3` statement (default)
- `.gitlab-ci.yml` — pipeline that rewrites the S3 clause to LOCAL INFILE for the MySQL stage, then (manually) runs the original S3 statement against a real cluster

## Sample table

```sql
CREATE TABLE customers (
  id          INT PRIMARY KEY,
  name        VARCHAR(100) NOT NULL,
  email       VARCHAR(255),
  signup_date DATE,
  balance     DECIMAL(10,2)
);
```

## Canonical statement (Aurora / S3)

```sql
LOAD DATA FROM S3 's3-us-east-1://my-bucket/imports/customers.csv'
INTO TABLE customers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(id, name, email, signup_date, balance);
```

Authenticates purely through an IAM role attached to the cluster — there are no `aws_access_key_id` / `aws_secret_access_key` options in the SQL. One-time setup:

1. Create an IAM role allowing `s3:GetObject` and `s3:ListBucket` on the bucket.
2. Attach it: `aws rds add-role-to-db-cluster --db-cluster-identifier <cluster> --feature-name s3Import --role-arn <arn>`.
3. Set the cluster parameter `aws_default_s3_role` to the role's ARN (older Aurora versions use `aurora_load_from_s3_role`).
4. Grant the DB user access: Aurora MySQL 3 → `GRANT AWS_LOAD_S3_ACCESS TO 'user'@'%'; SET DEFAULT ROLE AWS_LOAD_S3_ACCESS TO 'user'@'%';`. Aurora MySQL 2 → `GRANT LOAD FROM S3 ON *.* TO 'user'@'%';`.
5. The cluster needs network access to S3 (VPC endpoint or NAT).

Extras Aurora supports that plain INFILE does not: a `PREFIX` clause to load multiple files at once, and a `MANIFEST` option pointing at a JSON list of files. A bucket in another region requires the `s3-<region>://` URI form and adds cross-region transfer costs.

Aurora also supports `LOAD DATA LOCAL INFILE` from a client, but that is not what this pipeline uses for the Aurora stage — it tests the real S3 path.

## MySQL equivalent (LOCAL INFILE)

What the pipeline produces for the MySQL test stage:

```sql
LOAD DATA LOCAL INFILE '/path/to/repo/sql/sample_customers.csv'
INTO TABLE customers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(id, name, email, signup_date, balance);
```

Two things must be enabled:

- **Server:** start MySQL with `--local-infile=1` (command flag or config). Without it the server rejects LOCAL requests.
- **Client:** pass `--local-infile=1` to the `mysql` CLI. The client disables LOCAL INFILE by default as a safety measure.

## Main differences

- **LOCAL:** `LOAD DATA LOCAL INFILE` reads from the *client* machine instead of the server. Aurora supports LOCAL INFILE from a client but has no server-side INFILE at all — S3 replaces it.
- **Security:** plain MySQL uses file paths and the FILE privilege for server-side INFILE; LOCAL INFILE needs no FILE privilege but does need `local_infile=1` on both sides. Aurora uses the IAM role on the cluster plus a database grant, with no credentials in the SQL.
- **URI format:** `s3://bucket/key` works for a same-region bucket; `s3-<region>://bucket/key` names the region explicitly.

## GitLab pipeline

The `.gitlab-ci.yml` has two stages:

1. **test-mysql** (automatic) — runs the MySQL 8.0 image as both the job container and a service with alias `mysql`. The service is started with `--local-infile=1` and `--secure-file-priv=NULL`. A before-script loop waits for `mysqladmin ping`, then a `sed` one-liner rewrites the S3 source clause in `sql/load_data.sql` into `LOAD DATA LOCAL INFILE` pointing at `$CI_PROJECT_DIR/sql/sample_customers.csv`. The rewritten statement is loaded with `--local-infile=1` on the client. The job counts rows in `customers` and fails if it is not 2.
2. **test-aurora** (manual) — same MySQL client image, but connects to your real Aurora host using CI/CD variables (`AURORA_HOST`, `AURORA_PORT`, `AURORA_USER`, `AURORA_PASSWORD`, `AURORA_DATABASE`). No rewrite happens — the original S3 statement from `sql/load_data.sql` runs as-is. It creates the table, loads, and counts again.

No volume mounts, no Runner privileges required.

## Why this matters for testing

The repository's default statement is the real production one (S3). CI proves it works by temporarily translating it to LOCAL INFILE against a disposable MySQL container, then the manual stage confirms the untouched S3 version against Aurora. The only line that changes is the source clause.
