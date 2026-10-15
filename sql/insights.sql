-- High-level financial totals and average order metrics
select
    count(distinct fo.order_sk) as total_orders,
    sum(foi.quantity) as total_units_sold,
    round(sum(foi.gross_amount), 2) as gross_revenue,
    round(sum(foi.discount_amount), 2) as total_discount,
    round(sum(foi.net_amount), 2) as net_revenue,
    -- Effective discount across all sales
    round((sum(foi.discount_amount) / nullif(sum(foi.gross_amount), 0) * 100)::numeric, 2) as discount_rate_pct,
    -- Average order value (AOV)
    round((sum(foi.net_amount) / nullif(count(distinct fo.order_sk), 0))::numeric, 2) as aov,
    -- Units per order
    round((sum(foi.quantity)::numeric / nullif(count(distinct fo.order_sk), 0)), 2) as units_per_order
from analytics.fact_orders fo
join analytics.fact_order_items foi
    on fo.order_sk = foi.order_sk;

-- Monthly net sales, MoM delta, and running total revenue
with monthly_summary as (
    select
        d.year_month,
        count(distinct fo.order_sk) as total_orders,
        sum(foi.quantity) as units_sold,
        round(sum(foi.net_amount), 2) as net_revenue
    from analytics.fact_orders fo
    join analytics.fact_order_items foi 
        on fo.order_sk = foi.order_sk
    join analytics.dim_date d 
        on fo.order_date_key = d.date_key
    where fo.order_date_key <> -1
    group by d.year_month
)
select
    year_month,
    total_orders,
    units_sold,
    net_revenue,
    coalesce(lag(net_revenue) over (order by year_month), 0.00) as prev_month_revenue,
    -- Dollar change vs previous month
    round((net_revenue - lag(net_revenue) over (order by year_month))::numeric, 2) as mom_change,
    -- Percentage change vs previous month
    round(
        ( (net_revenue - lag(net_revenue) over (order by year_month)) 
          / nullif(lag(net_revenue) over (order by year_month), 0) * 100
        )::numeric, 
        2
    ) as mom_growth_pct,
    -- Cumulative sales to date
    sum(net_revenue) over (order by year_month) as running_total_revenue
from monthly_summary
order by year_month;

-- Evaluates delivery performance and late shipment rates by state
select 
    shipping_state,
    count(*) as total_orders,
    round(avg(fulfillment_lead_days), 1) as avg_days_to_ship,
    round(avg(delivery_transit_days), 1) as avg_days_in_transit,
    round(avg(total_fulfillment_days), 1) as avg_total_delivery_days,
    -- Orders taking more than 7 days total to arrive
    count(*) filter (where total_fulfillment_days > 14) as delayed_orders,
    round(100.0 * count(*) filter (where total_fulfillment_days > 14) / count(*), 2) as delay_rate_pct
from analytics.fact_orders
where order_status = 'Completed'
  and total_fulfillment_days is not null
group by shipping_state
having count(*) >= 100
order by avg_total_delivery_days desc;

-- Highlights high-revenue subcategories vs low-margin categories and stockouts
select 
    p.category,
    p.subcategory,
    sum(oi.quantity) as units_sold,
    round(sum(oi.net_amount), 2) as net_sales,
    -- Margin calculation: (Revenue - Cost of Goods Sold) / Revenue
    round(sum(oi.net_amount - (oi.quantity * p.cost)), 2) as gross_profit,
    round(
        (sum(oi.net_amount - (oi.quantity * p.cost)) / nullif(sum(oi.net_amount), 0) * 100)::numeric, 
        2
    ) as gross_margin_pct,
    sum(p.stock_quantity) as remaining_inventory,
    -- Flag popular items running out of inventory
    case 
        when sum(p.stock_quantity) = 0 then 'Stockout'
        when sum(p.stock_quantity) < 1000 then 'Low Stock'
        else 'Healthy'
    end as inventory_status
from analytics.fact_order_items oi
join analytics.dim_products p 
    on oi.product_sk = p.product_sk
where oi.product_sk <> -1
group by p.category, p.subcategory
order by net_sales desc;

-- Tracks user drop-off across the 4 key funnel stages by traffic source
with funnel_counts as (
    select 
        coalesce(utm_source, 'Direct') as traffic_source,
        device_type,
        count(*) filter (where event_type = 'page_view') as page_views,
        count(*) filter (where event_type = 'product_view') as product_views,
        count(*) filter (where event_type = 'add_to_cart') as cart_adds,
        count(*) filter (where event_type = 'purchase') as purchases
    from analytics.fact_web_events
    group by utm_source, device_type
)
select 
    traffic_source,
    device_type,
    page_views,
    product_views,
    cart_adds,
    purchases,
    -- End-to-end conversion rate
    round((purchases::numeric / nullif(page_views, 0) * 100), 2) as conversion_rate_pct,
    -- Cart abandonment: users who added to cart but didn't buy
    round(((cart_adds - purchases)::numeric / nullif(cart_adds, 0) * 100), 2) as cart_abandonment_pct
from funnel_counts
where page_views > 0
order by purchases desc;