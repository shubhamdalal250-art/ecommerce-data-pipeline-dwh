-- ============================================================================
-- ELT Pipeline: Load analytics.dim_customers
-- Cleans names, emails, addresses, parses all 10 date formats deterministically
-- ============================================================================

INSERT INTO analytics.dim_customers (
    customer_id,
    first_name,
    last_name,
    full_name,
    email,
    phone,
    segment,
    marketing_channel,
    city,
    state,
    country,
    registration_date
)
WITH parsed_source AS (
    SELECT 
        customer_id::INTEGER AS customer_id,
        TRIM(first_name) AS first_name,
        TRIM(last_name) AS last_name,
        CONCAT(TRIM(first_name), ' ', TRIM(last_name)) AS full_name,
        LOWER(TRIM(email)) AS email,
        TRIM(phone) AS phone,
        COALESCE(NULLIF(TRIM(segment), ''), 'Unknown') AS segment,
        COALESCE(NULLIF(TRIM(marketing_channel), ''), 'Direct') AS marketing_channel,
        
        -- Clean dirty characters (e.g., '#') from city names
        REGEXP_REPLACE(TRIM(city), '[^a-zA-Z\s\.\-]', '', 'g') AS city,
        TRIM(state) AS state,
        
        -- Standardize country variants to ISO code 'US'
        CASE 
            WHEN UPPER(TRIM(country)) IN ('US', 'USA', 'U.S.A.', 'UNITED STATES') THEN 'US'
            ELSE COALESCE(UPPER(TRIM(country)), 'US')
        END AS country,
        
        -- Deterministic Multi-Format Date Parser
        CASE 
            -- 1. Standard ISO Date (YYYY-MM-DD)
            WHEN registration_date ~ '^\d{4}-\d{2}-\d{2}$' 
                THEN registration_date::DATE

            -- 2. Standard ISO Timestamp (YYYY-MM-DD HH:MI:SS)
            WHEN registration_date ~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' 
                THEN registration_date::TIMESTAMP::DATE

            -- 3. Slashed ISO Date (YYYY/MM/DD)
            WHEN registration_date ~ '^\d{4}/\d{2}/\d{2}$'
                THEN TO_DATE(registration_date, 'YYYY/MM/DD')

            -- 4. Compact 8-digit String (YYYYMMDD)
            WHEN registration_date ~ '^\d{8}$'
                THEN TO_DATE(registration_date, 'YYYYMMDD')

            -- 5. Standard Slashed US Date (MM/DD/YYYY)
            WHEN registration_date ~ '^\d{2}/\d{2}/\d{4}$'
                THEN TO_DATE(registration_date, 'MM/DD/YYYY')

            -- 6. Day + 3-Letter Month + 4-digit Year (e.g., '18 Jul 2024')
            WHEN registration_date ~ '^\d{1,2} [A-Za-z]{3} \d{4}$'
                THEN TO_DATE(registration_date, 'DD Mon YYYY')

            -- 7. Full Month Name + Day + Year (e.g., 'September 28, 2024')
            WHEN registration_date ~ '^[A-Za-z]+ \d{1,2}, \d{4}$'
                THEN TO_DATE(registration_date, 'FMMonth DD, YYYY')

            -- 8. Dashed with 4-digit Year: Check if token 1 is Day (>12) or Month (<=12)
            WHEN registration_date ~ '^\d{2}-\d{2}-\d{4}$' THEN
                CASE 
                    WHEN SPLIT_PART(registration_date, '-', 1)::INTEGER > 12 
                        THEN TO_DATE(registration_date, 'DD-MM-YYYY')
                    ELSE TO_DATE(registration_date, 'MM-DD-YYYY')
                END

            -- 9. Dashed with 2-digit Year: Check if token 1 is Day (>12) or Month (<=12)
            WHEN registration_date ~ '^\d{2}-\d{2}-\d{2}$' THEN
                CASE 
                    WHEN SPLIT_PART(registration_date, '-', 1)::INTEGER > 12 
                        THEN TO_DATE(registration_date, 'DD-MM-YY')
                    ELSE TO_DATE(registration_date, 'MM-DD-YY')
                END

            ELSE NULL
        END AS registration_date,

        -- Deduplication window: keep the latest physical record per customer_id
        ROW_NUMBER() OVER (
            PARTITION BY customer_id::INTEGER 
            ORDER BY ctid DESC
        ) AS row_num
    FROM staging.customers
    WHERE customer_id IS NOT NULL
)
SELECT 
    customer_id,
    first_name,
    last_name,
    full_name,
    email,
    phone,
    segment,
    marketing_channel,
    city,
    state,
    country,
    registration_date
FROM parsed_source
WHERE row_num = 1
ON CONFLICT (customer_id) DO UPDATE SET
    first_name        = EXCLUDED.first_name,
    last_name         = EXCLUDED.last_name,
    full_name         = EXCLUDED.full_name,
    email             = EXCLUDED.email,
    phone             = EXCLUDED.phone,
    segment           = EXCLUDED.segment,
    marketing_channel = EXCLUDED.marketing_channel,
    city              = EXCLUDED.city,
    state             = EXCLUDED.state,
    country           = EXCLUDED.country,
    registration_date = EXCLUDED.registration_date;

select * from analytics.dim_customers
limit 5;


-- ============================================================================
-- ELT Pipeline: Load analytics.dim_products
-- Cleans names, standardizes categories, imputes missing financial metrics
-- ============================================================================

WITH raw_cleaned AS (
    SELECT
        product_id::INTEGER AS product_id,
        TRIM(product_name) AS product_name,
        
        -- Clean dirty characters (*, @, $, etc.) and collapse whitespace
        REGEXP_REPLACE(
            TRIM(REGEXP_REPLACE(category, '[^a-zA-Z0-9\s\&]', '', 'g')), 
            '\s+', ' ', 'g'
        ) AS raw_clean_category,
        
        TRIM(subcategory) AS subcategory,
        COALESCE(NULLIF(TRIM(brand), ''), 'Unbranded') AS brand,
        price::NUMERIC(12, 2) AS price,
        cost::NUMERIC(12, 2) AS cost,
        COALESCE(stock_quantity::INTEGER, 0) AS stock_quantity,
        COALESCE(weight_kg::NUMERIC(8, 2), 0.00) AS weight_kg,
        ctid
    FROM staging.products
    WHERE product_id IS NOT NULL
),
imputed_category AS (
    SELECT
        rc.*,
        -- Window imputation: find the first non-null parent category for this subcategory
        INITCAP(
            COALESCE(
                NULLIF(rc.raw_clean_category, ''),
                FIRST_VALUE(NULLIF(rc.raw_clean_category, '')) OVER (
                    PARTITION BY rc.subcategory 
                    ORDER BY CASE WHEN rc.raw_clean_category IS NOT NULL AND rc.raw_clean_category <> '' THEN 0 ELSE 1 END
                ),
                'Unassigned'
            )
        ) AS clean_category
    FROM raw_cleaned rc
),
subcategory_medians AS (
    -- Aggregated CTE: Computes medians per subcategory without window conflicts
    SELECT
        subcategory,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY price) AS subcategory_median_price,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY cost) AS subcategory_median_cost
    FROM raw_cleaned
    GROUP BY subcategory
),
transformed_products AS (
    SELECT
        ic.product_id,
        COALESCE(NULLIF(ic.product_name, ''), 'Unnamed Product') AS product_name,
        ic.clean_category AS category,
        INITCAP(ic.subcategory) AS subcategory,
        ic.brand,
        
        -- Price Imputation: Row Price -> Subcategory Median -> 0.00
        ROUND(COALESCE(ic.price, sm.subcategory_median_price, 0.00)::NUMERIC, 2) AS price,
        
        -- Cost Imputation: Row Cost -> Subcategory Median -> 50% of Price -> 0.00
        ROUND(COALESCE(ic.cost, sm.subcategory_median_cost, ic.price * 0.50, 0.00)::NUMERIC, 2) AS cost,
        
        GREATEST(ic.stock_quantity, 0) AS stock_quantity,
        ic.weight_kg,
        TRUE AS is_active,
        
        ROW_NUMBER() OVER (
            PARTITION BY ic.product_id 
            ORDER BY ic.ctid DESC
        ) AS row_num
    FROM imputed_category ic
    LEFT JOIN subcategory_medians sm 
        ON ic.subcategory = sm.subcategory
)
INSERT INTO analytics.dim_products (
    product_id,
    product_name,
    category,
    subcategory,
    brand,
    price,
    cost,
    stock_quantity,
    weight_kg,
    is_active
)
SELECT 
    product_id,
    product_name,
    category,
    subcategory,
    brand,
    price,
    cost,
    stock_quantity,
    weight_kg,
    is_active
FROM transformed_products
WHERE row_num = 1
ON CONFLICT (product_id) DO UPDATE SET
    product_name   = EXCLUDED.product_name,
    category       = EXCLUDED.category,
    subcategory    = EXCLUDED.subcategory,
    brand          = EXCLUDED.brand,
    price          = EXCLUDED.price,
    cost           = EXCLUDED.cost,
    stock_quantity = EXCLUDED.stock_quantity,
    weight_kg      = EXCLUDED.weight_kg,
    is_active      = EXCLUDED.is_active;

select * from analytics.dim_products
limit 5;

-- ============================================================================
-- DDL & POPULATION: analytics.dim_date
-- Granularity: One row per calendar day (2020 through 2029) + Unknown sentinel (-1)
-- ============================================================================

DROP TABLE IF EXISTS analytics.dim_date CASCADE;

CREATE TABLE analytics.dim_date (
    -- Smart Primary Key (YYYYMMDD)
    date_key               INTEGER PRIMARY KEY,

    -- Calendar Attributes
    full_date              DATE NOT NULL UNIQUE,
    year                   INTEGER NOT NULL,
    quarter                INTEGER NOT NULL,
    month                  INTEGER NOT NULL,
    month_name             VARCHAR(20) NOT NULL,
    month_name_short       CHAR(3) NOT NULL,
    week_of_year           INTEGER NOT NULL,
    day_of_month           INTEGER NOT NULL,
    day_of_week            INTEGER NOT NULL, -- 1 = Sunday, 7 = Saturday
    day_name               VARCHAR(20) NOT NULL,
    day_name_short         CHAR(3) NOT NULL,
    is_weekend             BOOLEAN NOT NULL,
    is_month_end           BOOLEAN NOT NULL,
    year_month             CHAR(7) NOT NULL  -- 'YYYY-MM'
);

-- ============================================================================
-- Step 1: Generate 10 Full Years of Calendar Days (3,653 days)
-- ============================================================================
INSERT INTO analytics.dim_date (
    date_key,
    full_date,
    year,
    quarter,
    month,
    month_name,
    month_name_short,
    week_of_year,
    day_of_month,
    day_of_week,
    day_name,
    day_name_short,
    is_weekend,
    is_month_end,
    year_month
)
SELECT
    TO_CHAR(d, 'YYYYMMDD')::INTEGER                                AS date_key,
    d::DATE                                                        AS full_date,
    EXTRACT(YEAR FROM d)::INTEGER                                  AS year,
    EXTRACT(QUARTER FROM d)::INTEGER                               AS quarter,
    EXTRACT(MONTH FROM d)::INTEGER                                 AS month,
    TRIM(TO_CHAR(d, 'Month'))                                      AS month_name,
    TRIM(TO_CHAR(d, 'Mon'))                                        AS month_name_short,
    EXTRACT(WEEK FROM d)::INTEGER                                  AS week_of_year,
    EXTRACT(DAY FROM d)::INTEGER                                   AS day_of_month,
    EXTRACT(DOW FROM d)::INTEGER + 1                               AS day_of_week,
    TRIM(TO_CHAR(d, 'Day'))                                        AS day_name,
    TRIM(TO_CHAR(d, 'Dy'))                                         AS day_name_short,
    CASE WHEN EXTRACT(ISODOW FROM d) IN (6, 7) THEN TRUE ELSE FALSE END AS is_weekend,
    CASE WHEN d::DATE = (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE THEN TRUE ELSE FALSE END AS is_month_end,
    TO_CHAR(d, 'YYYY-MM')                                          AS year_month
FROM GENERATE_SERIES('2020-01-01'::DATE, '2029-12-31'::DATE, INTERVAL '1 day') AS s(d)
ON CONFLICT (date_key) DO NOTHING;

-- ============================================================================
-- Step 2: Insert Sentinel Record for Unknown / Missing Dates (-1)
-- Handles missing order_date values in staging.orders
-- ============================================================================
INSERT INTO analytics.dim_date (
    date_key,
    full_date,
    year,
    quarter,
    month,
    month_name,
    month_name_short,
    week_of_year,
    day_of_month,
    day_of_week,
    day_name,
    day_name_short,
    is_weekend,
    is_month_end,
    year_month
)
VALUES (
    -1,
    '1900-01-01'::DATE,
    1900,
    0,
    0,
    'Unknown',
    'Unk',
    0,
    0,
    0,
    'Unknown',
    'Unk',
    FALSE,
    FALSE,
    '1900-00'
)
ON CONFLICT (date_key) DO NOTHING;

SELECT COUNT(*) FROM analytics.dim_date;

-- ============================================================================
-- ELT Pipeline: Load analytics.fact_orders
-- Granularity: One row per unique order.
-- Fixes staging column names, handles float string IDs, repairs timelines.
-- ============================================================================

WITH deduplicated_orders AS (
    SELECT
        -- Safe numeric casting for IDs formatted as '9441.0'
        FLOOR(NULLIF(TRIM(order_id), '')::NUMERIC)::INTEGER AS order_id,
        FLOOR(NULLIF(TRIM(customer_id), '')::NUMERIC)::INTEGER AS customer_id,
        
        COALESCE(NULLIF(INITCAP(TRIM(order_status)), ''), 'Unknown') AS order_status,
        COALESCE(NULLIF(TRIM(payment_method), ''), 'Unknown') AS payment_method,
        NULLIF(TRIM(discount_code), '') AS discount_code,
        
        -- Exact column names from staging.orders
        TRIM(shipping_address_city) AS shipping_city,
        TRIM(shipping_address_state) AS shipping_state,
        
        -- Standardize shipping country
        CASE 
            WHEN UPPER(TRIM(shipping_address_country)) IN ('US', 'USA', 'U.S.A.', 'UNITED STATES') THEN 'US'
            ELSE COALESCE(UPPER(TRIM(shipping_address_country)), 'US')
        END AS shipping_country,

        -- Standardize base dates
        CASE 
            WHEN order_date ~ '^\d{4}-\d{2}-\d{2}' THEN order_date::DATE
            ELSE NULL 
        END AS raw_order_date,
        
        CASE 
            WHEN shipped_date ~ '^\d{4}-\d{2}-\d{2}' THEN shipped_date::DATE 
            ELSE NULL 
        END AS raw_shipped_date,
        
        CASE 
            WHEN delivered_date ~ '^\d{4}-\d{2}-\d{2}' THEN delivered_date::DATE 
            ELSE NULL 
        END AS raw_delivered_date,

        -- Deduplicate: keep the first physical occurrence of each order_id
        ROW_NUMBER() OVER (
            PARTITION BY FLOOR(NULLIF(TRIM(order_id), '')::NUMERIC)::INTEGER 
            ORDER BY ctid ASC
        ) AS row_num
    FROM staging.orders
    WHERE order_id IS NOT NULL 
      AND TRIM(order_id) <> ''
),
corrected_timelines AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        payment_method,
        discount_code,
        shipping_city,
        shipping_state,
        shipping_country,
        raw_order_date AS order_date,
        raw_shipped_date AS shipped_date,
        
        -- Fix timeline corruption and canceled shipments
        CASE 
            WHEN order_status = 'Cancelled' THEN NULL
            
            -- Fix the synthetic -10 day subtraction bug: invert to +10 days
            WHEN raw_delivered_date IS NOT NULL 
             AND raw_shipped_date IS NOT NULL 
             AND raw_delivered_date < raw_shipped_date 
                THEN (raw_shipped_date + INTERVAL '10 days')::DATE
                
            ELSE raw_delivered_date
        END AS delivered_date
    FROM deduplicated_orders
    WHERE row_num = 1
),
enriched_orders AS (
    SELECT
        ct.order_id,
        
        -- Surrogate Key Lookup: Map missing/unmatched customers to -1
        COALESCE(dc.customer_sk, -1) AS customer_sk,
        
        -- Smart Date Keys: Map missing dates to -1
        COALESCE(TO_CHAR(ct.order_date, 'YYYYMMDD')::INTEGER, -1) AS order_date_key,
        TO_CHAR(ct.shipped_date, 'YYYYMMDD')::INTEGER AS shipped_date_key,
        TO_CHAR(ct.delivered_date, 'YYYYMMDD')::INTEGER AS delivered_date_key,
        
        ct.order_status,
        ct.payment_method,
        ct.discount_code,
        ct.shipping_city,
        ct.shipping_state,
        ct.shipping_country,
        ct.order_date,
        ct.shipped_date,
        ct.delivered_date,
        
        -- Pre-calculated Logistics Lifecycle Metrics
        CASE 
            WHEN ct.shipped_date IS NOT NULL AND ct.order_date IS NOT NULL 
                THEN (ct.shipped_date - ct.order_date)
            ELSE NULL 
        END AS fulfillment_lead_days,
        
        CASE 
            WHEN ct.delivered_date IS NOT NULL AND ct.shipped_date IS NOT NULL 
                THEN (ct.delivered_date - ct.shipped_date)
            ELSE NULL 
        END AS delivery_transit_days,
        
        CASE 
            WHEN ct.delivered_date IS NOT NULL AND ct.order_date IS NOT NULL 
                THEN (ct.delivered_date - ct.order_date)
            ELSE NULL 
        END AS total_fulfillment_days
    FROM corrected_timelines ct
    LEFT JOIN analytics.dim_customers dc 
        ON ct.customer_id = dc.customer_id
)
INSERT INTO analytics.fact_orders (
    order_id,
    customer_sk,
    order_date_key,
    shipped_date_key,
    delivered_date_key,
    order_status,
    payment_method,
    discount_code,
    shipping_city,
    shipping_state,
    shipping_country,
    order_date,
    shipped_date,
    delivered_date,
    fulfillment_lead_days,
    delivery_transit_days,
    total_fulfillment_days
)
SELECT 
    order_id,
    customer_sk,
    order_date_key,
    shipped_date_key,
    delivered_date_key,
    order_status,
    payment_method,
    discount_code,
    shipping_city,
    shipping_state,
    shipping_country,
    order_date,
    shipped_date,
    delivered_date,
    fulfillment_lead_days,
    delivery_transit_days,
    total_fulfillment_days
FROM enriched_orders
ON CONFLICT (order_id) DO UPDATE SET
    customer_sk            = EXCLUDED.customer_sk,
    order_date_key         = EXCLUDED.order_date_key,
    shipped_date_key       = EXCLUDED.shipped_date_key,
    delivered_date_key     = EXCLUDED.delivered_date_key,
    order_status           = EXCLUDED.order_status,
    payment_method         = EXCLUDED.payment_method,
    discount_code          = EXCLUDED.discount_code,
    shipping_city          = EXCLUDED.shipping_city,
    shipping_state         = EXCLUDED.shipping_state,
    shipping_country       = EXCLUDED.shipping_country,
    order_date             = EXCLUDED.order_date,
    shipped_date           = EXCLUDED.shipped_date,
    delivered_date         = EXCLUDED.delivered_date,
    fulfillment_lead_days  = EXCLUDED.fulfillment_lead_days,
    delivery_transit_days  = EXCLUDED.delivery_transit_days,
    total_fulfillment_days = EXCLUDED.total_fulfillment_days;

SELECT *
FROM staging.order_items
LIMIT 5;

-- ============================================================================
-- ELT Pipeline: Reload analytics.fact_order_items with Price Imputation
-- Falls back to dim_products.price when staging unit_price is missing or zero.
-- ============================================================================

TRUNCATE TABLE analytics.fact_order_items RESTART IDENTITY;

WITH cleaned_items AS (
    SELECT
        -- Safe numeric casting for IDs and quantities with '.0'
        FLOOR(NULLIF(TRIM(order_item_id), '')::NUMERIC)::INTEGER AS order_item_id,
        FLOOR(NULLIF(TRIM(order_id), '')::NUMERIC)::INTEGER AS order_id,
        FLOOR(NULLIF(TRIM(product_id), '')::NUMERIC)::INTEGER AS product_id,
        
        GREATEST(FLOOR(NULLIF(TRIM(quantity), '')::NUMERIC)::INTEGER, 1) AS quantity,
        NULLIF(TRIM(unit_price), '')::NUMERIC(12, 2) AS raw_unit_price,
        COALESCE(NULLIF(TRIM(discount_amount), '')::NUMERIC(12, 2), 0.00) AS discount_amount,
        
        -- Deduplicate if any identical order_item_id exists
        ROW_NUMBER() OVER (
            PARTITION BY FLOOR(NULLIF(TRIM(order_item_id), '')::NUMERIC)::INTEGER 
            ORDER BY ctid ASC
        ) AS row_num
    FROM staging.order_items
    WHERE order_item_id IS NOT NULL 
      AND TRIM(order_item_id) <> ''
),
resolved_line_items AS (
    SELECT
        ci.order_item_id,
        ci.order_id,
        fo.order_sk,
        COALESCE(dp.product_sk, -1) AS product_sk,
        ci.quantity,
        
        -- Price Fallback: Raw Staging Price -> Catalog Price -> 0.00
        ROUND(
            COALESCE(
                NULLIF(ci.raw_unit_price, 0.00),
                NULLIF(dp.price, 0.00),
                0.00
            )::NUMERIC, 
            2
        ) AS unit_price,
        
        ci.discount_amount
    FROM cleaned_items ci
    JOIN analytics.fact_orders fo 
        ON ci.order_id = fo.order_id
    LEFT JOIN analytics.dim_products dp 
        ON ci.product_id = dp.product_id
    WHERE ci.row_num = 1
)
INSERT INTO analytics.fact_order_items (
    order_item_id,
    order_id,
    order_sk,
    product_sk,
    quantity,
    unit_price,
    discount_amount,
    gross_amount,
    net_amount
)
SELECT 
    order_item_id,
    order_id,
    order_sk,
    product_sk,
    quantity,
    unit_price,
    discount_amount,
    ROUND((quantity * unit_price)::NUMERIC, 2) AS gross_amount,
    GREATEST(ROUND(((quantity * unit_price) - discount_amount)::NUMERIC, 2), 0.00) AS net_amount
FROM resolved_line_items;

-- ============================================================================
-- ELT Pipeline: Load analytics.fact_web_events
-- Granularity: One row per discrete user interaction / page hit.
-- Resolves customer_sk and product_sk with -1 sentinels, deterministically
-- parses all 8 timestamp patterns, and standardizes web session attribution.
-- ============================================================================

WITH cleaned_events AS (
    SELECT
        -- Primary business key
        FLOOR(NULLIF(TRIM(event_id), '')::NUMERIC)::INTEGER AS event_id,
        
        -- Safe UUID conversion
        CASE 
            WHEN session_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                THEN session_id::UUID
            ELSE NULL 
        END AS session_id,
        
        -- Clean natural keys for surrogate joins (handling float string artifacts)
        FLOOR(NULLIF(TRIM(customer_id), '')::NUMERIC)::INTEGER AS customer_id,
        FLOOR(NULLIF(TRIM(product_id), '')::NUMERIC)::INTEGER AS product_id,
        
        LOWER(TRIM(event_type)) AS event_type,
        
        -- Complete Multi-Pattern Timestamp Parser
        CASE 
            -- 1. Standard ISO Date or Timestamp
            WHEN event_timestamp ~ '^\d{4}-\d{2}-\d{2}' 
                THEN event_timestamp::TIMESTAMP WITH TIME ZONE

            -- 2. Slashed ISO Date (YYYY/MM/DD)
            WHEN event_timestamp ~ '^\d{4}/\d{2}/\d{2}'
                THEN TO_TIMESTAMP(event_timestamp, 'YYYY/MM/DD')

            -- 3. Standard Slashed US Date (MM/DD/YYYY)
            WHEN event_timestamp ~ '^\d{2}/\d{2}/\d{4}'
                THEN TO_TIMESTAMP(event_timestamp, 'MM/DD/YYYY')

            -- 4. Compact 8-digit numeric (YYYYMMDD)
            WHEN event_timestamp ~ '^\d{8}$'
                THEN TO_TIMESTAMP(event_timestamp, 'YYYYMMDD')

            -- 5. Day + 3-Letter Month + Year (e.g., '18 Dec 2024')
            WHEN event_timestamp ~ '^\d{1,2} [A-Za-z]{3} \d{4}'
                THEN TO_TIMESTAMP(event_timestamp, 'DD Mon YYYY')

            -- 6. Full Month Name + Day + Year (e.g., 'October 09, 2024')
            WHEN event_timestamp ~ '^[A-Za-z]+ \d{1,2}, \d{4}'
                THEN TO_TIMESTAMP(event_timestamp, 'FMMonth DD, YYYY')

            -- 7. Dashed with 4-digit Year: Check if token 1 is Day (>12) or Month (<=12)
            WHEN event_timestamp ~ '^\d{2}-\d{2}-\d{4}' THEN
                CASE 
                    WHEN SPLIT_PART(event_timestamp, '-', 1)::INTEGER > 12 
                        THEN TO_TIMESTAMP(event_timestamp, 'DD-MM-YYYY')
                    ELSE TO_TIMESTAMP(event_timestamp, 'MM-DD-YYYY')
                END

            -- 8. Dashed with 2-digit Year: Check if token 1 is Day (>12) or Month (<=12)
            WHEN event_timestamp ~ '^\d{2}-\d{2}-\d{2}' THEN
                CASE 
                    WHEN SPLIT_PART(event_timestamp, '-', 1)::INTEGER > 12 
                        THEN TO_TIMESTAMP(event_timestamp, 'DD-MM-YY')
                    ELSE TO_TIMESTAMP(event_timestamp, 'MM-DD-YY')
                END

            ELSE '1900-01-01 00:00:00+00'::TIMESTAMP WITH TIME ZONE
        END AS event_timestamp,

        TRIM(page_url) AS page_url,
        NULLIF(TRIM(referrer_url), '') AS referrer_url,
        COALESCE(NULLIF(TRIM(device_type), ''), 'Unknown') AS device_type,
        COALESCE(NULLIF(TRIM(browser), ''), 'Unknown') AS browser,
        COALESCE(NULLIF(UPPER(TRIM(country)), ''), 'Unknown') AS country,

        -- Campaign Attribution (Degenerate Dimensions)
        COALESCE(NULLIF(TRIM(utm_source), ''), 'Direct') AS utm_source,
        COALESCE(NULLIF(TRIM(utm_medium), ''), 'None') AS utm_medium,
        COALESCE(NULLIF(TRIM(utm_campaign), ''), 'Organic') AS utm_campaign,

        -- Deduplication window: keep the first physical record per event_id
        ROW_NUMBER() OVER (
            PARTITION BY FLOOR(NULLIF(TRIM(event_id), '')::NUMERIC)::INTEGER 
            ORDER BY ctid ASC
        ) AS row_num
    FROM staging.web_events
    WHERE event_id IS NOT NULL 
      AND TRIM(event_id) <> ''
),
resolved_events AS (
    SELECT
        ce.event_id,
        ce.session_id,

        -- Surrogate Key Lookups: Map missing/unmatched to -1
        COALESCE(dc.customer_sk, -1) AS customer_sk,
        COALESCE(dp.product_sk, -1) AS product_sk,

        -- Smart Date Key pointing to dim_date
        COALESCE(TO_CHAR(ce.event_timestamp, 'YYYYMMDD')::INTEGER, -1) AS event_date_key,

        ce.event_type,
        ce.event_timestamp,
        ce.page_url,
        ce.referrer_url,
        ce.device_type,
        ce.browser,
        ce.country,
        ce.utm_source,
        ce.utm_medium,
        ce.utm_campaign
    FROM cleaned_events ce
    LEFT JOIN analytics.dim_customers dc 
        ON ce.customer_id = dc.customer_id
    LEFT JOIN analytics.dim_products dp 
        ON ce.product_id = dp.product_id
    WHERE ce.row_num = 1
)
INSERT INTO analytics.fact_web_events (
    event_id,
    session_id,
    customer_sk,
    product_sk,
    event_date_key,
    event_type,
    event_timestamp,
    page_url,
    referrer_url,
    device_type,
    browser,
    country,
    utm_source,
    utm_medium,
    utm_campaign
)
SELECT 
    event_id,
    session_id,
    customer_sk,
    product_sk,
    event_date_key,
    event_type,
    event_timestamp,
    page_url,
    referrer_url,
    device_type,
    browser,
    country,
    utm_source,
    utm_medium,
    utm_campaign
FROM resolved_events
ON CONFLICT (event_id) DO UPDATE SET
    session_id      = EXCLUDED.session_id,
    customer_sk     = EXCLUDED.customer_sk,
    product_sk      = EXCLUDED.product_sk,
    event_date_key  = EXCLUDED.event_date_key,
    event_type      = EXCLUDED.event_type,
    event_timestamp = EXCLUDED.event_timestamp,
    page_url        = EXCLUDED.page_url,
    referrer_url    = EXCLUDED.referrer_url,
    device_type     = EXCLUDED.device_type,
    browser         = EXCLUDED.browser,
    country         = EXCLUDED.country,
    utm_source      = EXCLUDED.utm_source,
    utm_medium      = EXCLUDED.utm_medium,
    utm_campaign    = EXCLUDED.utm_campaign;

SELECT 
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'analytics'
ORDER BY tablename, indexname;


