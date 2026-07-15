USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WALMART_WH;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

SET run_id = (SELECT MAX(run_id) FROM BACKTEST_FORECASTS);

-- Forward forecast: pick each series' champion out of FORWARD_RAW.
CREATE OR REPLACE TABLE FUTURE_FORECASTS AS
SELECT
    f.series_key, cs.champion_model AS model,
    f.target_week, f.horizon_step,
    ROUND(f.y_pred,2)  AS forecast,
    ROUND(f.y_lower,2) AS lower_80,
    ROUND(f.y_upper,2) AS upper_80
FROM FORWARD_RAW f
JOIN CHAMPION_SELECTION cs
  ON cs.series_key = f.series_key AND cs.champion_model = f.model
WHERE f.run_id = $run_id;

-- Champion's most-recent backtest window vs actuals.
CREATE OR REPLACE TABLE FORECAST_VS_ACTUAL AS
WITH last_origin AS (
    SELECT series_key, MAX(origin_date) AS origin_date
    FROM BACKTEST_FORECASTS WHERE run_id = $run_id GROUP BY series_key
)
SELECT
    b.series_key, b.model, b.target_week, b.horizon_step,
    b.is_holiday, ROUND(b.y_true,2) AS actual, ROUND(b.y_pred,2) AS forecast
FROM BACKTEST_FORECASTS b
JOIN last_origin lo ON lo.series_key = b.series_key AND lo.origin_date = b.origin_date
JOIN CHAMPION_SELECTION cs ON cs.series_key = b.series_key AND cs.champion_model = b.model
WHERE b.run_id = $run_id;

SELECT COUNT(*) forward_rows FROM FUTURE_FORECASTS;
SELECT COUNT(*) vs_actual_rows FROM FORECAST_VS_ACTUAL;

/* Next: 07_agent_semantic_search.sql */
