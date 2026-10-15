select * from staging.orders
where order_id::integer= 477;

with ranked_orders as (
select *,
	row_number() over(partition by order_id) as row_numbers
	from staging.orders
)
select * from ranked_orders
where row_numbers >1;

-- ============================================================================
-- SCRIPT NAME:  02_data_profiling.sql
-- PROJECT:      End-to-End E-Commerce ELT Pipeline
-- ENVIRONMENT:  PostgreSQL 14+ / pgAdmin 4
-- PURPOSE:      Comprehensive exploratory data profiling across raw staging tables
--               (orders, order_items, customers, products, web_events).
--               Identifies primary key integrity, null rates, string corruption,
--               temporal contradictions, and categorical inconsistencies.
-- ============================================================================

-- ============================================================================
-- SECTION 1: STAGING.ORDERS PROFILING
-- ============================================================================

-- 1.1 Completeness, Null Rates, and Duplicate Order ID Metrics
SELECT 
    'total_rows' AS metric_name, 
    COUNT(*)::NUMERIC AS metric_value
FROM staging.orders

UNION ALL

SELECT 
    'null_order_id', 
    COUNT(*)::NUMERIC
FROM staging.orders
WHERE order_id IS NULL OR TRIM(order_id) = ''

UNION ALL

SELECT 
    'null_customer_id', 
    COUNT(*)::NUMERIC
FROM staging.orders
WHERE customer_id IS NULL OR TRIM(customer_id) = ''

UNION ALL

SELECT 
    'null_order_date', 
    COUNT(*)::NUMERIC
FROM staging.orders
WHERE order_date IS NULL OR TRIM(order_date) = ''

UNION ALL

SELECT 
    'duplicated_order_id', 
    COUNT(*)::NUMERIC
FROM (
    SELECT order_id
    FROM staging.orders
    GROUP BY order_id
    HAVING COUNT(*) > 1
) sub_distinct_dupes

UNION ALL

SELECT 
    'rows_with_duplicate_order_id', 
    COALESCE(SUM(cnt), 0)::NUMERIC
FROM (
    SELECT COUNT(*) AS cnt
    FROM staging.orders
    GROUP BY order_id
    HAVING COUNT(*) > 1
) sub_total_dupe_rows;


-- 1.2 Inspect Exact Row Clones Across Duplicate Order IDs
-- Checks whether duplicated order IDs represent identical clones or conflicting updates
WITH duplicate_ids AS (
    SELECT order_id
    FROM staging.orders
    GROUP BY order_id
    HAVING COUNT(*) > 1
    LIMIT 3
)
SELECT o.*
FROM staging.orders o
JOIN duplicate_ids d 
    ON o.order_id = d.order_id
ORDER BY o.order_id;


-- 1.3 Temporal Integrity and Logistics Lifecycle Validation
-- Identifies chronological violations (e.g., delivered before order, shipped before order)
SELECT
    COUNT(*) AS total_orders,
    
    -- Date Presence
    COUNT(*) FILTER (WHERE order_date IS NOT NULL AND TRIM(order_date) <> '') AS populated_order_dates,
    COUNT(*) FILTER (WHERE shipped_date IS NOT NULL AND TRIM(shipped_date) <> '') AS populated_shipped_dates,
    COUNT(*) FILTER (WHERE delivered_date IS NOT NULL AND TRIM(delivered_date) <> '') AS populated_delivered_dates,

    -- Chronological Lifecycle Violations
    COUNT(*) FILTER (
        WHERE order_date ~ '^\d{4}-\d{2}-\d{2}' 
          AND shipped_date ~ '^\d{4}-\d{2}-\d{2}'
          AND shipped_date::DATE < order_date::DATE
    ) AS shipped_before_order_count,

    COUNT(*) FILTER (
        WHERE order_date ~ '^\d{4}-\d{2}-\d{2}' 
          AND delivered_date ~ '^\d{4}-\d{2}-\d{2}'
          AND delivered_date::DATE < order_date::DATE
    ) AS delivered_before_order_count,

    COUNT(*) FILTER (
        WHERE shipped_date ~ '^\d{4}-\d{2}-\d{2}' 
          AND delivered_date ~ '^\d{4}-\d{2}-\d{2}'
          AND delivered_date::DATE < shipped_date::DATE
    ) AS delivered_before_shipped_count
FROM staging.orders;


-- 1.4 Deep-Dive Sample: Negative Delivery Lag Anomaly
-- Isolates the systematic synthetic script bug where delivered_date = shipped_date - 10 days
SELECT 
    order_id,
    order_status,
    order_date,
    shipped_date,
    delivered_date,
    (delivered_date::DATE - shipped_date::DATE) AS delivery_lag_days,
    (shipped_date::DATE - order_date::DATE) AS fulfillment_lag_days
FROM staging.orders
WHERE order_date ~ '^\d{4}-\d{2}-\d{2}'
  AND shipped_date ~ '^\d{4}-\d{2}-\d{2}'
  AND delivered_date ~ '^\d{4}-\d{2}-\d{2}'
  AND delivered_date::DATE < shipped_date::DATE
ORDER BY delivery_lag_days ASC
LIMIT 10;


-- 1.5 Diagnostic Inspection of Specific Missing Keys / Filter Outliers
SELECT *
FROM staging.orders
WHERE customer_id IS NULL OR TRIM(customer_id) = ''
LIMIT 5;

SELECT 
    order_date, 
    COUNT(*) AS frequency
FROM staging.orders
WHERE order_date IS NULL OR TRIM(order_date) = ''
GROUP BY order_date;


-- ============================================================================
-- SECTION 2: STAGING.ORDER_ITEMS PROFILING
-- ============================================================================

-- 2.1 Volume, Null Rates, and Duplicate Grain Profiling
SELECT 
    'total_rows' AS metric_name, 
    COUNT(*)::NUMERIC AS metric_value
FROM staging.order_items

UNION ALL

SELECT 
    'null_order_id', 
    COUNT(*)::NUMERIC
FROM staging.order_items
WHERE order_id IS NULL OR TRIM(order_id) = ''

UNION ALL

SELECT 
    'null_product_id', 
    COUNT(*)::NUMERIC
FROM staging.order_items
WHERE product_id IS NULL OR TRIM(product_id) = ''

UNION ALL

SELECT 
    'distinct_orders_represented', 
    COUNT(DISTINCT order_id)::NUMERIC
FROM staging.order_items

UNION ALL

SELECT 
    'distinct_products_represented', 
    COUNT(DISTINCT product_id)::NUMERIC
FROM staging.order_items

UNION ALL

SELECT 
    'total_order_items_count', 
    COUNT(*)::NUMERIC
FROM staging.order_items

UNION ALL

SELECT 
    'dup_order_item_id_count', 
    COUNT(*)::NUMERIC
FROM (
    SELECT order_item_id
    FROM staging.order_items
    GROUP BY order_item_id
    HAVING COUNT(*) > 1
) sub_dupe_items

UNION ALL

SELECT 
    'sum_uncleaned_line_total', 
    SUM(line_total::NUMERIC)
FROM staging.order_items
WHERE line_total ~ '^\d+(\.\d+)?$';


-- 2.2 Identify Composite Key Duplication (order_id + product_id)
-- Evaluates whether individual orders repeat the exact same product SKU across multiple rows
SELECT 
    order_id, 
    product_id, 
    COUNT(*) AS item_occurrences
FROM staging.order_items
GROUP BY order_id, product_id
HAVING COUNT(*) > 1
ORDER BY item_occurrences DESC
LIMIT 10;


-- 2.3 Inspect Specific Multi-Item Order
SELECT *
FROM staging.order_items
WHERE order_id = '5869';


-- 2.4 Float String Artifact Audit in product_id
-- Detects upstream pandas export artifacts (e.g., '1465.0' stored as text)
SELECT 
    COUNT(*) FILTER (WHERE product_id LIKE '%.0') AS float_formatted_product_ids,
    COUNT(*) FILTER (WHERE product_id NOT LIKE '%.0' AND product_id IS NOT NULL) AS clean_product_ids,
    COUNT(*) FILTER (WHERE product_id IS NULL OR TRIM(product_id) = '') AS missing_product_ids
FROM staging.order_items;


-- ============================================================================
-- SECTION 3: STAGING.CUSTOMERS PROFILING
-- ============================================================================

-- 3.1 Preview Sample Rows
SELECT * 
FROM staging.customers
LIMIT 5;


-- 3.2 Single-Scan Completeness, Key Integrity, and String Noise Audit
SELECT
    COUNT(*) AS total_rows,
    
    -- Primary Key Integrity
    COUNT(DISTINCT customer_id) AS distinct_customer_ids,
    COUNT(*) FILTER (WHERE customer_id IS NULL) AS null_customer_id,
    
    -- Completeness Metrics
    COUNT(*) FILTER (WHERE email IS NULL OR TRIM(email) = '') AS missing_email_count,
    ROUND(100.0 * COUNT(*) FILTER (WHERE email IS NULL OR TRIM(email) = '') / COUNT(*), 2) AS missing_email_pct,
    COUNT(*) FILTER (WHERE phone IS NULL OR TRIM(phone) = '') AS missing_phone_count,
    COUNT(*) FILTER (WHERE segment IS NULL OR TRIM(segment) = '') AS missing_segment_count,
    COUNT(*) FILTER (WHERE registration_date IS NULL OR TRIM(registration_date) = '') AS missing_reg_date_count,

    -- String Noise Detection (Padding & Special Characters)
    COUNT(*) FILTER (WHERE city IS NOT NULL AND LENGTH(city) <> LENGTH(TRIM(city))) AS city_whitespace_noise_count,
    COUNT(*) FILTER (WHERE city ~ '[^a-zA-Z\s\.\-]') AS city_special_char_count,

    -- Format Validity (RFC Email Regex)
    COUNT(*) FILTER (
        WHERE email IS NOT NULL 
          AND TRIM(email) <> '' 
          AND email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    ) AS malformed_email_count,
    
    -- Shared Email Accounts Cardinality Benchmark
    COUNT(DISTINCT LOWER(TRIM(email))) AS distinct_cleaned_emails
FROM staging.customers;


-- 3.3 Identify Shared Email Accounts (Multi-Account Collision)
SELECT 
    LOWER(TRIM(email)) AS normalized_email,
    COUNT(*) AS account_count,
    ARRAY_AGG(customer_id) AS associated_customer_ids
FROM staging.customers
WHERE email IS NOT NULL AND TRIM(email) <> ''
GROUP BY LOWER(TRIM(email))
HAVING COUNT(*) > 1
ORDER BY account_count DESC
LIMIT 20;


-- 3.4 Geographic Synonym Distribution (Country Column)
SELECT 
    COALESCE(country, '[NULL]') AS raw_country_value,
    COUNT(*) AS frequency,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_share
FROM staging.customers
GROUP BY country
ORDER BY frequency DESC;


-- 3.5 Registration Date Pattern Taxonomy
SELECT 
    CASE 
        WHEN registration_date ~ '^\d{4}-\d{2}-\d{2}$' THEN 'ISO Date (YYYY-MM-DD)'
        WHEN registration_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' THEN 'ISO Timestamp (YYYY-MM-DD HH:MI:SS)'
        WHEN registration_date ~ '^\d{2}/\d{2}/\d{4}$' THEN 'Slash Format (MM/DD/YYYY or DD/MM/YYYY)'
        WHEN registration_date ~ '^\d{2}-\d{2}-\d{4}$' THEN 'Dash Format (DD-MM-YYYY or MM-DD-YYYY)'
        WHEN registration_date IS NULL OR TRIM(registration_date) = '' THEN '[NULL / Empty]'
        ELSE 'Irregular / Unparseable'
    END AS detected_date_pattern,
    COUNT(*) AS record_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_share
FROM staging.customers
GROUP BY 1
ORDER BY record_count DESC;


-- 3.6 Sample Irregular Non-ISO Registration Dates
SELECT 
    registration_date,
    COUNT(*) AS frequency
FROM staging.customers
WHERE registration_date !~ '^\d{4}-\d{2}-\d{2}$'
GROUP BY registration_date
ORDER BY frequency DESC
LIMIT 25;


-- ============================================================================
-- SECTION 4: STAGING.PRODUCTS PROFILING
-- ============================================================================

-- 4.1 Preview Sample Rows
SELECT * 
FROM staging.products
LIMIT 5;


-- 4.2 Quality, Completeness, Domain Rules, and Whitespace Audit
SELECT
    COUNT(*) AS total_rows,
    
    -- Primary Key Integrity
    COUNT(DISTINCT product_id) AS distinct_product_ids,
    COUNT(*) FILTER (WHERE product_id IS NULL) AS null_product_id_count,

    -- Completeness Gaps
    COUNT(*) FILTER (WHERE product_name IS NULL OR TRIM(product_name) = '') AS missing_name_count,
    COUNT(*) FILTER (WHERE category IS NULL OR TRIM(category) = '') AS missing_category_count,
    COUNT(*) FILTER (WHERE subcategory IS NULL OR TRIM(subcategory) = '') AS missing_subcategory_count,
    COUNT(*) FILTER (WHERE brand IS NULL OR TRIM(brand) = '') AS missing_brand_count,
    COUNT(*) FILTER (WHERE price IS NULL) AS null_price_count,
    COUNT(*) FILTER (WHERE cost IS NULL) AS null_cost_count,

    -- Domain & Validity Rules
    COUNT(*) FILTER (WHERE price <= 0) AS non_positive_price_count,
    COUNT(*) FILTER (WHERE cost <= 0) AS non_positive_cost_count,
    COUNT(*) FILTER (WHERE price < cost) AS negative_margin_count,
    COUNT(*) FILTER (WHERE stock_quantity < 0) AS negative_stock_count,

    -- Whitespace Padding Detection
    COUNT(*) FILTER (WHERE category IS NOT NULL AND LENGTH(category) <> LENGTH(TRIM(category))) AS category_whitespace_noise_count,
    COUNT(*) FILTER (WHERE subcategory IS NOT NULL AND LENGTH(subcategory) <> LENGTH(TRIM(subcategory))) AS subcategory_whitespace_noise_count
FROM staging.products;


-- 4.3 Category Imputation Mapping (Category vs. Subcategory Hierarchy)
-- Verifies whether subcategories map cleanly to parent categories or contain corruption
SELECT 
    subcategory,
    COUNT(*) AS total_occurrences,
    COUNT(*) FILTER (WHERE category IS NULL OR TRIM(category) = '') AS null_category_count,
    COUNT(DISTINCT category) FILTER (WHERE category IS NOT NULL AND TRIM(category) <> '') AS distinct_mapped_categories,
    MAX(category) AS sample_valid_category
FROM staging.products
GROUP BY subcategory
ORDER BY null_category_count DESC;


-- 4.4 Category Price Outlier Detection (Corrected PostgreSQL Aggregate Join Pattern)
-- Identifies products priced significantly higher than the category median (3x IQR fence)
WITH category_benchmarks AS (
    SELECT
        TRIM(category) AS clean_category,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY price) AS q1,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY price) AS median_price,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY price) AS q3
    FROM staging.products
    WHERE price IS NOT NULL 
      AND category IS NOT NULL 
      AND TRIM(category) <> ''
    GROUP BY TRIM(category)
)
SELECT
    p.product_id,
    p.product_name,
    TRIM(p.category) AS category,
    p.price,
    p.cost,
    ROUND(cb.median_price::NUMERIC, 2) AS category_median,
    ROUND((p.price / NULLIF(cb.median_price, 0))::NUMERIC, 2) AS price_to_median_ratio,
    ROUND((cb.q3 + 3.0 * (cb.q3 - cb.q1))::NUMERIC, 2) AS extreme_upper_fence
FROM staging.products p
JOIN category_benchmarks cb 
    ON TRIM(p.category) = cb.clean_category
WHERE p.price > (cb.q3 + 3.0 * (cb.q3 - cb.q1))
ORDER BY price_to_median_ratio DESC
LIMIT 20;


-- ============================================================================
-- SECTION 5: STAGING.WEB_EVENTS PROFILING
-- ============================================================================

-- 5.1 Preview Sample Rows
SELECT * 
FROM staging.web_events
LIMIT 5;


-- 5.2 Clickstream Volume, Traffic Authentication, and Format Audit
SELECT
    COUNT(*) AS total_events,
    COUNT(DISTINCT session_id) AS distinct_sessions,
    
    -- Traffic Identification & User Attribution
    COUNT(*) FILTER (WHERE customer_id IS NOT NULL AND TRIM(customer_id) <> '') AS authenticated_events,
    COUNT(*) FILTER (WHERE customer_id IS NULL OR TRIM(customer_id) = '') AS anonymous_events,
    ROUND(100.0 * COUNT(*) FILTER (WHERE customer_id IS NULL OR TRIM(customer_id) = '') / COUNT(*), 2) AS anonymous_traffic_pct,

    -- Product Interaction Tracking
    COUNT(*) FILTER (WHERE product_id IS NOT NULL AND TRIM(product_id) <> '') AS product_tagged_events,
    
    -- Timestamp Formatting Verification
    COUNT(*) FILTER (WHERE event_timestamp ~ '^\d{4}-\d{2}-\d{2}') AS iso_date_count,
    COUNT(*) FILTER (WHERE event_timestamp !~ '^\d{4}-\d{2}-\d{2}') AS non_iso_date_count
FROM staging.web_events;
