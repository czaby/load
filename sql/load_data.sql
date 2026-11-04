LOAD DATA FROM S3 's3-us-east-1://my-bucket/imports/customers.csv'
INTO TABLE customers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(id, name, email, signup_date, balance);
