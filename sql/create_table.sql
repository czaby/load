CREATE TABLE customers (
  id          INT PRIMARY KEY,
  name        VARCHAR(100) NOT NULL,
  email       VARCHAR(255),
  signup_date DATE,
  balance     DECIMAL(10,2)
);
