
-- Data Engineering — Individual Assignment
-- Slowly Changing Dimension (SCD) — dim_customer for classicmodels

-- Name        : Devina Rahmadhita Dewantoro
-- Student ID  : 24/532725/PA/22528
-- =====================================================================

USE classicmodels;

-- STEP 2 — dim_customer DDL (SCD Type 2 structure)

DROP TABLE IF EXISTS dim_customer;

CREATE TABLE dim_customer (
    customer_key            INT AUTO_INCREMENT PRIMARY KEY,      -- surrogate key
    customerNumber          INT NOT NULL,                        -- natural key (Type 0)
    customerName            VARCHAR(50)  NOT NULL,                -- Type 1
    contactLastName         VARCHAR(50),                          -- Type 1
    contactFirstName        VARCHAR(50),                          -- Type 1
    addressLine1            VARCHAR(50),                          -- Type 2 (address block)
    addressLine2            VARCHAR(50),                          -- Type 2
    city                     VARCHAR(50),                          -- Type 2
    state                    VARCHAR(50),                          -- Type 2
    postalCode               VARCHAR(15),                          -- Type 2
    country                  VARCHAR(50),                          -- Type 2
    salesRepEmployeeNumber   INT,                                  -- Type 2 (the "trap" attribute)
    creditLimit               DECIMAL(10,2),                        -- Type 2
    effective_date           DATE NOT NULL,
    expiry_date               DATE NOT NULL DEFAULT '9999-12-31',
    is_current                 BOOLEAN NOT NULL DEFAULT TRUE,
    INDEX idx_customerNumber (customerNumber),
    INDEX idx_customerNumber_current (customerNumber, is_current)
);


INSERT INTO dim_customer
    (customerNumber, customerName, contactLastName, contactFirstName,
     addressLine1, addressLine2, city, state, postalCode, country,
     salesRepEmployeeNumber, creditLimit,
     effective_date, expiry_date, is_current)
SELECT
    customerNumber, customerName, contactLastName, contactFirstName,
    addressLine1, addressLine2, city, state, postalCode, country,
    salesRepEmployeeNumber, creditLimit,
    '2003-01-01' AS effective_date,   
    '9999-12-31' AS expiry_date,
    TRUE AS is_current
FROM customers;

-- STEP 3 — upsert_dim_customer stored procedure
-- Handles, in this order:
--   (a) brand-new customer            -> INSERT, is_current = TRUE
--   (b) existing customer, no Type-2
--       attribute change              -> no history row created
--                                        (Type-1 attrs refreshed in place)
--   (c) existing customer, Type-2
--       attribute changed             -> close old row, insert new row
--   (d) old rows are NEVER deleted or overwritten in place

DROP PROCEDURE IF EXISTS upsert_dim_customer;

DELIMITER $$

CREATE PROCEDURE upsert_dim_customer(
    IN p_customerNumber         INT,
    IN p_customerName           VARCHAR(50),
    IN p_contactLastName        VARCHAR(50),
    IN p_contactFirstName       VARCHAR(50),
    IN p_addressLine1           VARCHAR(50),
    IN p_addressLine2           VARCHAR(50),
    IN p_city                   VARCHAR(50),
    IN p_state                  VARCHAR(50),
    IN p_postalCode             VARCHAR(15),
    IN p_country                VARCHAR(50),
    IN p_salesRepEmployeeNumber INT,
    IN p_creditLimit            DECIMAL(10,2),
    IN p_effective_date         DATE
)
BEGIN
    DECLARE v_customer_key           INT;
    DECLARE v_addressLine1           VARCHAR(50);
    DECLARE v_addressLine2           VARCHAR(50);
    DECLARE v_city                   VARCHAR(50);
    DECLARE v_state                  VARCHAR(50);
    DECLARE v_postalCode             VARCHAR(15);
    DECLARE v_country                VARCHAR(50);
    DECLARE v_salesRepEmployeeNumber INT;
    DECLARE v_creditLimit            DECIMAL(10,2);
    DECLARE v_row_count               INT DEFAULT 0;

  
    SELECT COUNT(*) INTO v_row_count
    FROM dim_customer
    WHERE customerNumber = p_customerNumber
      AND is_current = TRUE;

    IF v_row_count = 0 THEN
        -- (a) Brand-new customer: simple insert.
        INSERT INTO dim_customer
            (customerNumber, customerName, contactLastName, contactFirstName,
             addressLine1, addressLine2, city, state, postalCode, country,
             salesRepEmployeeNumber, creditLimit,
             effective_date, expiry_date, is_current)
        VALUES
            (p_customerNumber, p_customerName, p_contactLastName, p_contactFirstName,
             p_addressLine1, p_addressLine2, p_city, p_state, p_postalCode, p_country,
             p_salesRepEmployeeNumber, p_creditLimit,
             p_effective_date, '9999-12-31', TRUE);

    ELSE
        
        SELECT customer_key, addressLine1, addressLine2, city, state, postalCode,
               country, salesRepEmployeeNumber, creditLimit
        INTO   v_customer_key, v_addressLine1, v_addressLine2, v_city, v_state,
               v_postalCode, v_country, v_salesRepEmployeeNumber, v_creditLimit
        FROM dim_customer
        WHERE customerNumber = p_customerNumber
          AND is_current = TRUE;

        IF  v_addressLine1           <=> p_addressLine1
        AND v_addressLine2           <=> p_addressLine2
        AND v_city                   <=> p_city
        AND v_state                  <=> p_state
        AND v_postalCode             <=> p_postalCode
        AND v_country                <=> p_country
        AND v_salesRepEmployeeNumber <=> p_salesRepEmployeeNumber
        AND v_creditLimit            <=> p_creditLimit
        THEN
            -- (b) No Type-2 change: idempotent. Only refresh Type-1
            -- attributes (identity/contact) in place on the same row —
            -- no new history row, no expiry.
            UPDATE dim_customer
            SET customerName    = p_customerName,
                contactLastName = p_contactLastName,
                contactFirstName = p_contactFirstName
            WHERE customer_key = v_customer_key;

        ELSE
            -- (c) A Type-2 attribute changed: close the old row, then
            -- insert the new current row. The old row is never deleted.
            UPDATE dim_customer
            SET expiry_date = DATE_SUB(p_effective_date, INTERVAL 1 DAY),
                is_current  = FALSE
            WHERE customer_key = v_customer_key;

            INSERT INTO dim_customer
                (customerNumber, customerName, contactLastName, contactFirstName,
                 addressLine1, addressLine2, city, state, postalCode, country,
                 salesRepEmployeeNumber, creditLimit,
                 effective_date, expiry_date, is_current)
            VALUES
                (p_customerNumber, p_customerName, p_contactLastName, p_contactFirstName,
                 p_addressLine1, p_addressLine2, p_city, p_state, p_postalCode, p_country,
                 p_salesRepEmployeeNumber, p_creditLimit,
                 p_effective_date, '9999-12-31', TRUE);
        END IF;
    END IF;
END$$

DELIMITER ;


-- STEP 4 — Demo: reassign a customer to a new sales rep
-- ILLUSTRATIVE customer/rep numbers — VERIFY against your own copy of
-- classicmodels before you run this (see note at top of file).

-- BEFORE: inspect the current row for the chosen customer.
SELECT * FROM dim_customer
WHERE customerNumber = 103 AND is_current = TRUE;

-- Fire the upsert with a changed salesRepEmployeeNumber (e.g. 1370 -> 1501)
-- and effective_date = 2005-06-01, everything else unchanged.
CALL upsert_dim_customer(
    103,                         -- p_customerNumber
    'Atelier graphique',         -- p_customerName
    'Schmitt',                   -- p_contactLastName
    'Carine',                    -- p_contactFirstName
    '54, rue Royale',            -- p_addressLine1
    NULL,                        -- p_addressLine2
    'Nantes',                    -- p_city
    NULL,                        -- p_state
    '44000',                     -- p_postalCode
    'France',                    -- p_country
    1501,                        -- p_salesRepEmployeeNumber  (NEW rep)
    21000.00,                    -- p_creditLimit
    '2005-06-01'                 -- p_effective_date
);

-- AFTER: both the closed historical row and the new current row should exist.
SELECT customer_key, customerNumber, salesRepEmployeeNumber, creditLimit,
       effective_date, expiry_date, is_current
FROM dim_customer
WHERE customerNumber = 103
ORDER BY effective_date;

-- Idempotency check: calling the procedure again with IDENTICAL values
-- must NOT create a new row.
CALL upsert_dim_customer(
    103, 'Atelier graphique', 'Schmitt', 'Carine',
    '54, rue Royale', NULL, 'Nantes', NULL, '44000', 'France',
    1501, 21000.00, '2005-06-15'
);

SELECT COUNT(*) AS row_count_should_still_be_2
FROM dim_customer
WHERE customerNumber = 103;


-- STEP 5 — Point-in-time analytical query
-- Business question #1: total order value credited to each sales rep
-- in a given year. Correct only because the join uses the
-- effective_date/expiry_date window on dim_customer, so each order is
-- matched to whichever sales rep actually owned the customer on the
-- order date — not to today's rep.

SELECT
    dc.salesRepEmployeeNumber,
    YEAR(o.orderDate)                              AS order_year,
    SUM(od.quantityOrdered * od.priceEach)          AS total_order_value
FROM orders o
JOIN orderdetails od
    ON o.orderNumber = od.orderNumber
JOIN dim_customer dc
    ON o.customerNumber = dc.customerNumber
   AND o.orderDate >= dc.effective_date
   AND o.orderDate <  dc.expiry_date
WHERE YEAR(o.orderDate) = 2005
GROUP BY dc.salesRepEmployeeNumber, YEAR(o.orderDate)
ORDER BY total_order_value DESC;

-- If dim_customer only kept SCD Type 1 (one row per customer, no
-- effective/expiry window), this same join would attribute EVERY
-- historical order for customer 103 to rep 1501 — including orders
-- placed in 2003-2004 while rep 1370 owned the account — silently
-- moving 1370's commission onto 1501's report.
