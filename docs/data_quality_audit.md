# Data Quality & Anomaly Audit Report

**Project:** E-Commerce Analytical Data Warehouse & ETL Pipeline  
**Target Environment:** PostgreSQL 14+ / Power BI  
**Author:** Shubham Dalal  
**Status:** Completed & Validated  

---

## 1. Executive Summary
During initial data profiling of raw staging tables (`staging.orders`, `staging.order_items`, `staging.customers`, `staging.products`, `staging.web_events`), several critical data quality anomalies were detected. If ingested uncorrected, these defects would have corrupted executive financial reporting, distorted delivery fulfillment SLAs, and broken relational joins.

This document formalizes the root-cause analysis and defensive engineering logic implemented in `sql/04_transformations.sql`.

---

## 2. Anomaly Remediation Matrix

| Staging Entity | Field / Column | Raw Anomaly Detected | Business & Analytical Impact | Engineering Remediation |
| :--- | :--- | :--- | :--- | :--- |
| `staging.orders` | `order_id` | 1,513 exact mechanical row clones (51,513 total vs 50,000 distinct). | Double-counting revenue; overstated sales volume by ~3.02%. | Deduplicated using `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY ctid ASC)` filtered to `row_num = 1`. |
| `staging.orders` | `customer_id` | 483 missing / null customer IDs. | Referential integrity constraint violations on foreign keys. | Mapped missing identifiers to the Sentinel Key `customer_sk = -1` ('Unknown Customer'). |
| `staging.orders` | `delivered_date`, `shipped_date` | 979 orders delivered before purchase date (`delivery_lag_days = -10`). | Negative fulfillment cycle times in Power BI; distorted logistics SLAs. | Detected synthetic generation bug (`shipped - 10`). Inverted interval to `(shipped_date + INTERVAL '10 days')::DATE`. Set canceled orders to `NULL`. |
| `staging.orders` | `order_status` | Missing / null statuses on completed orders. | Violates `NOT NULL` constraint on `fact_orders`. | Wrapped with `COALESCE(NULLIF(INITCAP(TRIM(order_status)), ''), 'Unknown')`. |
| `staging.order_items`| `product_id`, `quantity` | Upstream Pandas float string artifacts (`'734.0'`, `'3.0'`). | SQL cast error `22P02: invalid input syntax for integer`. | Converted using two-stage numeric casting: `FLOOR(NULLIF(TRIM(col), '')::NUMERIC)::INTEGER`. |
| `staging.order_items`| `line_total` | `line_total = quantity * unit_price`, ignoring `discount_amount`. | Inaccurate margin and top-line net sales reporting. | Recomputed gross and net metrics: `gross_amount = quantity * unit_price`, `net_amount = gross_amount - discount_amount`. |
| `staging.order_items`| `unit_price` | 1,280 items with `$0.00` or null unit price in staging. | Understated revenue on known product sales. | Fallback imputation: `COALESCE(NULLIF(raw_price, 0), dim_products.price, 0.00)`. |
| `staging.customers` | `registration_date` | 10 distinct, conflicting date format patterns (e.g., `DD Mon YYYY`, `MM-DD-YY`, `YYYY/MM/DD`). | SQL runtime exceptions (`22008: date/time field value out of range`). | Deterministic 9-branch regex routing engine using token range inspection (`SPLIT_PART`). |
| `staging.customers` | `city`, `country` | `#` punctuation noise in city names; 4-way US country synonym fragmentation (`USA`, `U.S.A.`, `United States`). | Split geographic grouping in Power BI maps and slicers. | Stripped non-alpha characters with `REGEXP_REPLACE`; harmonized all country variants to ISO code `'US'`. |
| `staging.products` | `category`, `subcategory` | Corrupted symbol injections (`'Aut&Omotive'`, `'Ca@Mping'`) and missing parent categories. | Fragmented visual legends and chart slicers. | Imputed parent categories via `FIRST_VALUE()` over subcategories; sanitized strings with regex. |
| `staging.web_events` | `event_timestamp` | Mixed ISO timestamps and alphanumeric text dates (`18 Dec 2024`). | Broken clickstream time intelligence and funnel tracking. | Unified all patterns into standard `TIMESTAMP WITH TIME ZONE` and generated `YYYYMMDD` integer date keys. |

---

## 3. Post-Load Validation Assertions

All automated assertions in `sql/05_warehouse_validation.sql` passed:
* **Row Count Reconciliation:** Exactly 50,000 unique orders loaded into `analytics.fact_orders`.
* **Referential Integrity:** 0 orphaned foreign keys across all fact tables.
* **Temporal Logic:** 0 orders with negative delivery or fulfillment transit days.
* **Financial Logic:** 0 records where gross revenue < net revenue.