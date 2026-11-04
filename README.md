# LOAD DATA Examples: MySQL INFILE vs Aurora FROM S3

This repository contains copy-pasteable examples for loading CSV data into MySQL using `LOAD DATA INFILE` and into Amazon Aurora MySQL using `LOAD DATA FROM S3`.

## The key insight

The syntax is nearly identical. The **only** difference is the source clause on the first line:

| Engine | Source clause |
| --- | --- |
| Plain MySQL | `LOAD DATA INFILE '/path/to/file.csv'` |
| Aurora MySQL | `LOAD DATA FROM S3 's3-us-east-1://bucket/key.csv'` |

Everything after that — `INTO TABLE`, `FIELDS TERMINATED BY`, `LINES TERMINATED BY`, `IGNORE 1 LINES`, and the column list — is word for word the same in both.

AWS documents this directly: the [Aurora MySQL Load from S3 guide](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Integrating.LoadFromS3.html) states that `LOAD DATA FROM S3` can load "any text file format that is supported by the MySQL `LOAD DATA INFILE` statement" and mirrors the INFILE parameters one for one. The Aurora docs even point readers to the MySQL LOAD DATA reference for parameter details.

## Files

- `sql/create_table.sql` — sample table definition
- `sql/sample_customers.csv` — two-row CSV matching the table
- `sql/load_mysql.sql` — `LOAD DATA INFILE` statement
- `sql/load_aurora.sql` — `LOAD DATA FROM S3` statement
- `.gitlab-ci.yml` — pipeline that tests the MySQL statement against a service container, then (manually) tests the Aurora statement against a real cluster

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

## Plain MySQL

```sql
LOAD DATA INFILE '/var/lib/mysql-files/customers.csv'
INTO TABLE customers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(id, name, email, signup_date, balance);
```

Reads from the server's `secure_file_priv` folder. Requires the `FILE` privilege. The file must be reachable by the MySQL server process.

## Aurora MySQL from S3

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

## Main differences

- **LOCAL:** `LOAD DATA LOCAL INFILE` reads from the *client* machine instead of the server. Aurora supports LOCAL INFILE from a client but has no server-side INFILE at all — S3 replaces it.
- **Security:** plain MySQL uses file paths and the FILE privilege; Aurora uses the IAM role on the cluster plus a database grant, with no credentials in the SQL.
- **URI format:** `s3://bucket/key` works for a same-region bucket; `s3-<region>://bucket/key` names the region explicitly.

## GitLab pipeline

The `.gitlab-ci.yml` has two stages:

1. **test-mysql** (automatic) — runs the MySQL 8.0 image as both the job container and a service with alias `mysql`. A before-script loop waits for `mysqladmin ping`, then loads the create-table SQL and the INFILE statement. The CSV is mounted into the container at `/var/lib/mysql-files/customers.csv` via a service-level volume, and the server is started with `--secure-file-priv=/var/lib/mysql-files` so the INFILE path is allowed. The job counts rows in `customers` and fails if it is not 2.
2. **test-aurora** (manual) — same MySQL client image, but connects to your real Aurora host using CI/CD variables (`AURORA_HOST`, `AURORA_PORT`, `AURORA_USER`, `AURORA_PASSWORD`, `AURORA_DATABASE`). A `sed` one-liner rewrites the INFILE source clause into `LOAD DATA FROM S3` with your bucket URI before running. Then it creates the table, loads, and counts again.

**Caveat on volume mounts:** service-level volume mounts only work if your GitLab Runner is configured for it — Docker socket exposed, privileged mode, or docker-in-docker. If your Runner cannot do mounts, switch to `LOAD DATA LOCAL INFILE` with `local_infile=1` enabled on both server and client, which avoids the file-path problem entirely. The pipeline file includes that fallback as a commented alternative.

## Why this matters for testing

Because the syntax is compatible, you can validate your Aurora SQL against a throwaway MySQL container in CI before ever touching a real cluster. The only line that must change between environments is the source clause — which is exactly what the pipeline's `sed` step handles.
