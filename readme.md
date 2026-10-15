# End-to-End E-Commerce ELT Pipeline & Kimball Data Warehouse

[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14%2B-blue?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![PowerBI](https://img.shields.io/badge/Power_BI-Desktop-F2C811?logo=powerbi&logoColor=black)](https://powerbi.microsoft.com/)
[![SQL](https://img.shields.io/badge/SQL-Kimball_Star_Schema-orange)](https://en.wikipedia.org/wiki/Star_schema)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An enterprise-grade ELT data pipeline, relational data warehouse, and business intelligence reporting suite built using **PostgreSQL (pgAdmin 4)** and **Power BI**. 

This project simulates a real-world enterprise analytics engineering lifecycle: diagnosing corrupted staging data, enforcing dimensional integrity through Kimball modeling, writing deterministic SQL transformations, and building an executive KPI dashboard.

---

## 1. Architecture & Data Flow

The project follows a decoupled **ELT (Extract, Load, Transform)** architecture:

```text
[Raw CSV Extracts]
        │
        ▼  (COPY / Bulk Ingestion)
[Staging Schema (PostgreSQL)] ── 5 Untyped Tables (orders, order_items, customers, products, web_events)
        │
        ▼  (02_data_profiling.sql -> Anomaly Discovery & Baseline Auditing)
[ELT Pipeline (04_transformations.sql)]
        │  ├── Deterministic Regex Multi-Pattern Date Parsing
        │  ├── Window Deduplication (ROW_NUMBER over ctid)
        │  ├── Temporal Anomaly Repair (Logistics Lead Times)
        │  ├── Subcategory Median Financial Imputation
        │  └── Surrogate Key Resolution & Sentinel (-1) Handling
        ▼
[Analytics Schema (PostgreSQL Star Schema)]
        │  ├── Dimensions: dim_customers, dim_products, dim_date
        │  └── Facts: fact_orders, fact_order_items, fact_web_events
        ▼
[Power BI Executive Dashboard] ── VertiPaq In-Memory Modeling, DAX Time Intelligence, & Visual Storytelling
```

---

## 2. Dimensional Data Model (Kimball Star Schema)

The destination schema (`analytics`) is architected as a high-performance **Star Schema** with surrogate keys, conformed dimensions, and enforced referential integrity:

```text
                    ┌─────────────────────────┐
                    │  analytics.dim_date     │
                    │─────────────────────────│
                    │ PK  date_key (YYYYMMDD) │
                    │     full_date           │
                    │     year, month, quarter│
                    │     is_weekend          │
                    └────────────┬────────────┘
                                 │
                 ┌───────────────┼───────────────┐
                 │ (order_date)  │ (event_date)  │
                 ▼               ▼               ▼
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
│  analytics.fact_orders   │   │analytics.fact_web_events │   │ analytics.dim_customers  │
│──────────────────────────│   │──────────────────────────│   │──────────────────────────│
│ PK  order_sk             │   │ PK  event_sk             │   │ PK  customer_sk          │
│ FK  customer_sk ─────────┼───┼──►  customer_sk          │◄──┼──   customer_id (Natural)│
│ FK  order_date_key       │   │ FK  product_sk           │   │     full_name            │
│     order_status         │   │ FK  event_date_key       │   │     email, phone         │
│     fulfillment_lead_days│   │     event_type           │   │     city, state, country │
│     total_fulfillment_days   │     session_id (UUID)    │   │     registration_date    │
└────────────┬─────────────┘   │     utm_source, campaign │   └──────────────────────────┘
             │                 └─────────────┬────────────┘
             │ (1:N)                         │
             ▼                               ▼
┌──────────────────────────┐   ┌──────────────────────────┐
│analytics.fact_order_items│   │  analytics.dim_products  │
│──────────────────────────│   │──────────────────────────│
│ PK  order_item_sk        │   │ PK  product_sk           │
│ FK  order_sk             │   │     product_id (Natural) │
│ FK  product_sk ──────────┼───┴──►  product_name         │
│     quantity, unit_price │         category, subcategory│
│     gross_amount         │         price, cost          │
│     net_amount           │         stock_quantity       │
└──────────────────────────┘   └──────────────────────────┘
```

### Key Dimensional Engineering Highlights:
* **Surrogate Keys:** System-generated `IDENTITY` keys isolate warehouse analytics from upstream operational ID shifts.
* **Sentinel Record (`-1`):** Every dimension includes an unknown/default member (`-1`). Fact records with missing keys (e.g., anonymous web traffic or unassigned order customer IDs) map to `-1`, maintaining 100% referential integrity without dropping financial transaction volume.
* **Role-Playing Calendar:** `analytics.dim_date` satisfies order placement, shipment, delivery, and web clickstream timestamps without duplicating calendar tables.

---

## 3. Data Engineering & Transformation Highlights

| Challenge | Engineering Resolution |
| :--- | :--- |
| **Cloned Order Duplication** | Staging contained 1,513 duplicated order pairs. Resolved using window partitioning `ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY ctid ASC)` filtered to `row_num = 1`. |
| **Temporal Logic Reversal** | 979 orders had synthetic negative delivery durations (`delivered = shipped - 10 days`). Inverted interval to `(shipped_date + INTERVAL '10 days')` and nullified canceled orders. |
| **Multi-Pattern Date Strings** | Raw dates arrived in 10 different formats (`DD Mon YYYY`, `MM-DD-YYYY`, `YYYY/MM/DD`, `YYYYMMDD`). Implemented deterministic regex pattern-matching with token range inspection. |
| **Python Float String Artifacts** | Numeric keys stored as text with `.0` (`'734.0'`). Handled via two-step casting: `FLOOR(val::NUMERIC)::INTEGER`. |
| **Missing Taxonomy & Financials** | Imputed missing product categories using `FIRST_VALUE()` over subcategories, and resolved missing unit prices with subcategory median fallbacks. |

*Full root-cause analysis is documented in [`docs/data_quality_audit.md`](docs/data_quality_audit.md).*

---

## 4. Key Business Insights

* **Topline Scale:** The business generated **$1.04 Billion** in Net Revenue across **50,000 unique orders**, selling 167K total units with an Average Order Value (AOV) of **$20,740.85**.
* **Discount Efficiency:** The effective blended discount rate sits at **~1.9%**, indicating high price realization with low margin erosion from promotions.
* **Category Dominance:** **Electronics** is the primary revenue driver (accounting for **47.1%** of total net sales), led by *Accessories* ($175.2M) and *Tablets* ($93.6M).
* **Fulfillment SLA Bottlenecks:** Across completed orders, **22.85%** experienced delivery fulfillment delays exceeding the 7-day target SLA.
* **Clickstream Funnel:** Analysis of 200,000 clickstream sessions showed an overall conversion rate of **~2.1%**, with significant desktop vs. mobile cart abandonment variations.

---

## 5. Repository Structure & How to Run

```text
ecommerce-data-pipeline-dwh/
│
├── sql/
│   ├── 01_staging_ddl.sql          # Staging tables & raw COPY statements
│   ├── 02_data_profiling.sql       # Exploratory profiling & anomaly detection queries
│   ├── 03_analytics_ddl.sql        # Star schema DDL, indexes, and sentinel records (-1)
│   ├── 04_transformations.sql      # Idempotent ELT cleaning & warehouse loading logic
│   └── 05_warehouse_validation.sql # Automated data quality assertion & reconciliation tests
│
├── docs/
│   └── data_quality_audit.md       # Profiling findings, root causes, & remediation matrix
│
├── pbix/
│   └── ecommerce_analytics.pbix    # Finished Power BI report file
│
├── assets/
│   └── dashboard_preview.png       # High-resolution screenshot of the executive dashboard
│
├── .gitignore                      # Ignore credentials, local temp files, and caches
└── README.md                       # Main project showcase and documentation
```

### Setup Instructions:
1. **Clone the repository:**
   ```bash
   git clone https://github.com/<your-username>/ecommerce-data-pipeline-dwh.git
   cd ecommerce-data-pipeline-dwh
   ```
2. **Execute SQL scripts sequentially in PostgreSQL / pgAdmin:**
   * Run `sql/01_staging_ddl.sql` (Creates staging tables and imports raw data).
   * Run `sql/02_data_profiling.sql` (Runs exploratory data quality profiling).
   * Run `sql/03_analytics_ddl.sql` (Builds the star schema and sentinel records).
   * Run `sql/04_transformations.sql` (Executes the ELT pipeline).
   * Run `sql/05_warehouse_validation.sql` (Verifies test assertions).
3. **Open Power BI:**
   * Open `pbix/ecommerce_analytics.pbix`.
   * Update the PostgreSQL data source credentials under **Transform Data $\rightarrow$ Data source settings** to point to your local PostgreSQL instance (`localhost:5432`).
   * Click **Refresh**.