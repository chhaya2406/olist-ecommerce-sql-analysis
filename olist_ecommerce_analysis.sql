CREATE DATABASE ecommerce_db;
USE ecommerce_db;

-- 1. Customers Table
CREATE TABLE customers (
    customer_id VARCHAR(50) PRIMARY KEY,
    customer_unique_id VARCHAR(50),
    customer_zip_code_prefix INT,
    customer_city VARCHAR(100),
    customer_state VARCHAR(10)
);

-- 2. Orders Table
CREATE TABLE orders (
    order_id VARCHAR(50) PRIMARY KEY,
    customer_id VARCHAR(50),
    order_status VARCHAR(50),
    order_purchase_timestamp DATETIME,
    order_approved_at DATETIME,
    order_delivered_carrier_date DATETIME,
    order_delivered_customer_date DATETIME,
    order_estimated_delivery_date DATETIME
);

-- 3. Order Items Table
CREATE TABLE order_items (
    order_id VARCHAR(50),
    order_item_id INT,
    product_id VARCHAR(50),
    seller_id VARCHAR(50),
    shipping_limit_date DATETIME,
    price DECIMAL(10, 2),
    freight_value DECIMAL(10, 2)
);
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;

USE ecommerce_db;

SELECT 'customers' AS tbl, COUNT(*) AS total_rows FROM customers;
SELECT 'orders', COUNT(*) FROM olist_orders_dataset;
SELECT 'order_items', COUNT(*) FROM olist_order_items_dataset;
SELECT 'payments', COUNT(*) FROM olist_order_payments_dataset;
SELECT 'products', COUNT(*) FROM olist_products_dataset;
SHOW TABLES;

-- =====================================================================
--  DATA VALIDATION AND COMPLETENESS CHECKS
-- Purpose: Verify record counts, foreign key integrity, and table preview.
-- Database: ecommerce_db
-- =====================================================================

USE ecommerce_db;

-- Step 1: Verify total row counts loaded across all tables
SELECT 'customers' AS table_name, COUNT(*) AS total_records FROM customers
UNION ALL
SELECT 'orders', COUNT(*) FROM olist_orders_dataset
UNION ALL
SELECT 'order_items', COUNT(*) FROM olist_order_items_dataset
UNION ALL
SELECT 'order_payments', COUNT(*) FROM olist_order_payments_dataset
UNION ALL
SELECT 'products', COUNT(*) FROM olist_products_dataset;

-- Step 2: Check for orphan orders (orders without a matching customer record)
SELECT 
    COUNT(DISTINCT o.order_id) AS total_orders,
    COUNT(DISTINCT c.customer_id) AS matched_customers,
    COUNT(DISTINCT o.order_id) - COUNT(DISTINCT c.customer_id) AS unmatched_orders
FROM olist_orders_dataset o
LEFT JOIN customers c 
    ON o.customer_id = c.customer_id;

-- Step 3: Inspect sample transactional rows from core tables
SELECT * FROM olist_orders_dataset LIMIT 5;
SELECT * FROM olist_order_items_dataset LIMIT 5;
SELECT * FROM olist_order_payments_dataset LIMIT 5;
SELECT * FROM customers LIMIT 5;
SELECT * FROM olist_products_dataset LIMIT 5;

-- =====================================================================
--  MONTHLY REVENUE & MOM GROWTH ANALYSIS
-- Purpose: Track monthly sales volume, order counts, and MoM expansion rates.
-- Techniques: CTEs, Window Functions (LAG), Date Parsing (STR_TO_DATE).
-- Database: ecommerce_db
-- =====================================================================

USE ecommerce_db;

WITH monthly_sales_summary AS (
    SELECT 
        DATE_FORMAT(
            STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'), 
            '%Y-%m-01'
        ) AS sales_month,
        ROUND(SUM(CAST(p.payment_value AS DECIMAL(10,2))), 2) AS gross_revenue,
        COUNT(DISTINCT o.order_id) AS total_orders
    FROM olist_orders_dataset o
    INNER JOIN olist_order_payments_dataset p 
        ON o.order_id = p.order_id
    WHERE o.order_status = 'delivered'
      AND o.order_purchase_timestamp IS NOT NULL
    GROUP BY DATE_FORMAT(
        STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'), 
        '%Y-%m-01'
    )
)
SELECT 
    sales_month,
    gross_revenue,
    total_orders,
    LAG(gross_revenue) OVER (ORDER BY sales_month) AS previous_month_revenue,
    ROUND(
        (gross_revenue - LAG(gross_revenue) OVER (ORDER BY sales_month)) 
        / NULLIF(LAG(gross_revenue) OVER (ORDER BY sales_month), 0) * 100.0, 
        2
    ) AS mom_growth_rate_pct
FROM monthly_sales_summary
ORDER BY sales_month ASC;

-- =====================================================================
--  CUSTOMER RFM SEGMENTATION
-- Purpose: Segment customer base by Recency, Frequency, and Monetary spend.
-- Techniques: Common Table Expressions (CTEs), Multi-Table Joins, NTILE Window Functions.
-- Note: Fixed reference snapshot date '2018-09-03' reflects dataset recency boundary.
-- Database: ecommerce_db
-- =====================================================================

USE ecommerce_db;

WITH rfm_base_metrics AS (
    SELECT 
        c.customer_unique_id,
        DATEDIFF(
            '2018-09-03', 
            MAX(STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s'))
        ) AS recency_in_days,
        COUNT(DISTINCT o.order_id) AS order_frequency,
        ROUND(SUM(CAST(oi.price AS DECIMAL(10,2))), 2) AS monetary_spend
    FROM customers c
    INNER JOIN olist_orders_dataset o 
        ON c.customer_id = o.customer_id
    INNER JOIN olist_order_items_dataset oi 
        ON o.order_id = oi.order_id
    WHERE o.order_status = 'delivered'
    GROUP BY c.customer_unique_id
)
SELECT 
    customer_unique_id,
    recency_in_days,
    order_frequency,
    monetary_spend,
    NTILE(4) OVER (ORDER BY recency_in_days DESC) AS r_quartile,
    NTILE(4) OVER (ORDER BY order_frequency ASC) AS f_quartile,
    NTILE(4) OVER (ORDER BY monetary_spend ASC) AS m_quartile
FROM rfm_base_metrics
ORDER BY monetary_spend DESC
LIMIT 100;

-- =====================================================================
--  PRODUCT CATEGORY CONCENTRATION ANALYSIS
-- Purpose: Identify top 10 revenue-generating product categories and their share of gross sales.
-- Techniques: Analytical Window Aggregations (SUM() OVER()), Inner Joins, Sub-aggregations.
-- Database: ecommerce_db
-- =====================================================================

USE ecommerce_db;

SELECT 
    p.product_category_name,
    COUNT(DISTINCT oi.order_id) AS total_orders_placed,
    ROUND(SUM(CAST(oi.price AS DECIMAL(10,2))), 2) AS category_revenue,
    ROUND(
        SUM(CAST(oi.price AS DECIMAL(10,2))) 
        / SUM(SUM(CAST(oi.price AS DECIMAL(10,2)))) OVER () * 100.0, 
        2
    ) AS revenue_contribution_pct
FROM olist_order_items_dataset oi
INNER JOIN olist_products_dataset p 
    ON oi.product_id = p.product_id
WHERE p.product_category_name IS NOT NULL
GROUP BY p.product_category_name
ORDER BY category_revenue DESC
LIMIT 10;

-- =====================================================================
-- SCRIPT 05: LOGISTICS PERFORMANCE & SHIPPING BOTTLENECKS
-- Purpose: Measure transit durations, compare actual delivery against estimated deadlines by state.
-- Techniques: Date Difference Calculations (DATEDIFF), Conditional Aggregations (CASE WHEN).
-- Database: ecommerce_db
-- =====================================================================

USE ecommerce_db;

SELECT 
    c.customer_state,
    COUNT(o.order_id) AS total_delivered_orders,
    ROUND(AVG(DATEDIFF(
        STR_TO_DATE(o.order_delivered_customer_date, '%Y-%m-%d %H:%i:%s'),
        STR_TO_DATE(o.order_purchase_timestamp, '%Y-%m-%d %H:%i:%s')
    )), 1) AS avg_transit_days,
    ROUND(AVG(DATEDIFF(
        STR_TO_DATE(o.order_delivered_customer_date, '%Y-%m-%d %H:%i:%s'),
        STR_TO_DATE(o.order_estimated_delivery_date, '%Y-%m-%d %H:%i:%s')
    )), 1) AS avg_delay_vs_estimated_days,
    SUM(CASE 
        WHEN STR_TO_DATE(o.order_delivered_customer_date, '%Y-%m-%d %H:%i:%s') > 
             STR_TO_DATE(o.order_estimated_delivery_date, '%Y-%m-%d %H:%i:%s') 
        THEN 1 ELSE 0 
    END) AS delayed_orders_count,
    ROUND(
        SUM(CASE 
            WHEN STR_TO_DATE(o.order_delivered_customer_date, '%Y-%m-%d %H:%i:%s') > 
                 STR_TO_DATE(o.order_estimated_delivery_date, '%Y-%m-%d %H:%i:%s') 
            THEN 1 ELSE 0 
        END) / COUNT(o.order_id) * 100.0, 
        2
    ) AS delayed_orders_pct
FROM olist_orders_dataset o
INNER JOIN customers c 
    ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
GROUP BY c.customer_state
ORDER BY delayed_orders_count DESC
LIMIT 10;

