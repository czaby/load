LOAD DATA LOCAL INFILE '/CI_PROJECT_DIR/sql/sample_customers.csv'
INTO TABLE customers
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(id, name, email, signup_date, balance);
