USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WALMART_WH;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

-- 1. SALES_WEEKLY: one clean row per store-dept-week, features joined, holidays named.
CREATE OR REPLACE TABLE SALES_WEEKLY AS
SELECT
    'S' || t.store || '_D' || t.dept        AS series_key,
    t.store, t.dept,
    s.type  AS store_type,
    s.size  AS store_size,
    t.week_date,
    YEAR(t.week_date)        AS year,
    MONTH(t.week_date)       AS month,
    WEEKOFYEAR(t.week_date)  AS week_of_year,
    t.weekly_sales,
    t.is_holiday,
    CASE
        WHEN t.week_date IN ('2010-02-12','2011-02-11','2012-02-10') THEN 'Super Bowl'
        WHEN t.week_date IN ('2010-09-10','2011-09-09','2012-09-07') THEN 'Labor Day'
        WHEN t.week_date IN ('2010-11-26','2011-11-25','2012-11-23') THEN 'Thanksgiving'
        WHEN t.week_date IN ('2010-12-31','2011-12-30','2012-12-28') THEN 'Christmas'
        ELSE NULL
    END AS holiday_name,
    f.temperature, f.fuel_price, f.cpi, f.unemployment,
    COALESCE(f.markdown1,0) AS markdown1, COALESCE(f.markdown2,0) AS markdown2,
    COALESCE(f.markdown3,0) AS markdown3, COALESCE(f.markdown4,0) AS markdown4,
    COALESCE(f.markdown5,0) AS markdown5
FROM RAW_TRAIN t
JOIN RAW_STORES s ON s.store = t.store
LEFT JOIN RAW_FEATURES f ON f.store = t.store AND f.week_date = t.week_date;

SELECT COUNT(*) rows, COUNT(DISTINCT series_key) series FROM SALES_WEEKLY;  -- 421570 / 3331

-- 2. DEMO_SERIES: 49 curated store-dept pairs (stores 20/A, 10/B, 37/C) spanning
--    seasonal strength 0.58-1.00, holiday lift 0.33x-3.09x, volume ~$140-$165k,
--    smooth + erratic. Chosen from a full-population scan.
CREATE OR REPLACE TABLE DEMO_SERIES (store NUMBER, dept NUMBER);
INSERT INTO DEMO_SERIES (store, dept) VALUES
(10,1),(10,5),(10,6),(10,7),(10,14),(10,16),(10,38),(10,41),(10,50),(10,55),
(10,56),(10,59),(10,67),(10,72),(10,82),(10,90),(10,92),(10,95),
(20,1),(20,5),(20,6),(20,7),(20,14),(20,16),(20,38),(20,41),(20,50),(20,55),
(20,56),(20,59),(20,67),(20,72),(20,82),(20,90),(20,92),(20,95),
(37,1),(37,5),(37,7),(37,14),(37,16),(37,38),(37,59),(37,67),(37,72),(37,82),
(37,90),(37,92),(37,95);

CREATE OR REPLACE VIEW SALES_WEEKLY_DEMO AS
SELECT w.* FROM SALES_WEEKLY w
JOIN DEMO_SERIES d ON d.store = w.store AND d.dept = w.dept;

SELECT COUNT(DISTINCT series_key) demo_series FROM SALES_WEEKLY_DEMO;  -- 49

-- 3. SERIES_CHARACTERISTICS: computed in-warehouse (auditable).
CREATE OR REPLACE TABLE SERIES_CHARACTERISTICS AS
WITH base AS (
    SELECT w.series_key, w.store, w.dept, w.store_type, w.store_size, w.weekly_sales, w.is_holiday,
           AVG(w.weekly_sales) OVER (PARTITION BY w.series_key) AS series_mean,
           AVG(w.weekly_sales) OVER (PARTITION BY w.series_key, w.week_of_year) AS woy_mean
    FROM SALES_WEEKLY w
),
agg AS (
    SELECT series_key, store, dept, store_type, store_size,
           COUNT(*) n_obs, AVG(weekly_sales) mean_sales, STDDEV(weekly_sales) std_sales,
           COUNT_IF(weekly_sales>0) pos_weeks,
           AVG(IFF(weekly_sales>0,weekly_sales,NULL)) mean_pos,
           STDDEV(IFF(weekly_sales>0,weekly_sales,NULL)) std_pos,
           AVG(IFF(is_holiday,weekly_sales,NULL)) mean_hol,
           AVG(IFF(NOT is_holiday,weekly_sales,NULL)) mean_nonhol,
           VARIANCE(weekly_sales - woy_mean) var_resid, VARIANCE(weekly_sales) var_total
    FROM base GROUP BY 1,2,3,4,5
),
calc AS (
    SELECT a.*,
        ROUND(std_sales/NULLIF(mean_sales,0),3) cv,
        ROUND(n_obs/NULLIF(pos_weeks,0),3) adi,
        ROUND(POWER(std_pos/NULLIF(mean_pos,0),2),3) cv2,
        ROUND(GREATEST(0,1-var_resid/NULLIF(var_total,0)),3) seas_strength,
        ROUND(mean_hol/NULLIF(mean_nonhol,0),3) holiday_lift
    FROM agg a
)
SELECT series_key, store, dept, store_type, store_size, n_obs,
       ROUND(mean_sales,2) mean_sales, cv, adi, cv2, seas_strength, holiday_lift,
       CASE WHEN adi<1.32 AND cv2<0.49 THEN 'smooth'
            WHEN adi>=1.32 AND cv2<0.49 THEN 'intermittent'
            WHEN adi<1.32 AND cv2>=0.49 THEN 'erratic'
            ELSE 'lumpy' END AS sb_class,
       (store,dept) IN (SELECT store,dept FROM DEMO_SERIES) AS is_demo
FROM calc;

SELECT sb_class, COUNT(*) series FROM SERIES_CHARACTERISTICS GROUP BY 1 ORDER BY 2 DESC;

/* Next: 03_backtest_schema.sql */
