USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WALMART_WH;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

SET run_id = (SELECT MAX(run_id) FROM BACKTEST_FORECASTS);

-- MASE scale per series = mean |seasonal(52) difference| over the full history.
CREATE OR REPLACE TEMP TABLE _mase_scale AS
SELECT series_key,
       AVG(ABS(weekly_sales - LAG(weekly_sales,52) OVER (PARTITION BY series_key ORDER BY week_date))) AS scale
FROM SALES_WEEKLY_DEMO
GROUP BY series_key;

-- Per series x model metrics.
CREATE OR REPLACE TABLE METRICS_BY_MODEL AS
WITH e AS (
    SELECT b.series_key, b.model, b.y_true, b.y_pred, b.is_holiday,
           ABS(b.y_true - b.y_pred) AS abs_err,
           IFF(b.is_holiday, 5.0, 1.0) AS w
    FROM BACKTEST_FORECASTS b
    WHERE b.run_id = $run_id
)
SELECT e.series_key, e.model,
       ROUND(SUM(w*abs_err)/NULLIF(SUM(w),0), 2)                                   AS wmae,
       ROUND(AVG(abs_err), 2)                                                      AS mae,
       ROUND(AVG(abs_err)/NULLIF(s.scale,0), 3)                                    AS mase,
       ROUND(AVG(2*abs_err/NULLIF(ABS(y_true)+ABS(y_pred),0))*100, 2)              AS smape,
       COUNT(*)                                                                    AS n_points
FROM e JOIN _mase_scale s ON s.series_key = e.series_key
GROUP BY e.series_key, e.model, s.scale;

-- Ranked leaderboard.
CREATE OR REPLACE TABLE MODEL_LEADERBOARD AS
SELECT series_key, model, wmae, mase, smape,
       RANK() OVER (PARTITION BY series_key ORDER BY wmae) AS rnk
FROM METRICS_BY_MODEL;

-- Champion with the seasonal-naive guardrail.
CREATE OR REPLACE TABLE CHAMPION_SELECTION AS
WITH naive AS (
    SELECT series_key, wmae AS naive_wmae FROM METRICS_BY_MODEL WHERE model='SEASONAL_NAIVE'
),
best AS (
    SELECT series_key, model AS best_model, wmae AS best_wmae
    FROM MODEL_LEADERBOARD WHERE rnk = 1
),
runner AS (
    SELECT series_key, model AS runner_up FROM MODEL_LEADERBOARD WHERE rnk = 2
),
g AS (SELECT naive_guardrail_pct FROM BACKTEST_CONFIG LIMIT 1)
SELECT
    b.series_key,
    (SELECT naive_guardrail_pct FROM g) AS guardrail_pct,
    n.naive_wmae,
    b.best_model, b.best_wmae,
    ROUND((n.naive_wmae - b.best_wmae)/NULLIF(n.naive_wmae,0)*100, 1) AS best_impr_pct,
    r.runner_up,
    -- apply guardrail
    CASE WHEN b.best_model <> 'SEASONAL_NAIVE'
              AND (n.naive_wmae - b.best_wmae)/NULLIF(n.naive_wmae,0)*100
                  >= (SELECT naive_guardrail_pct FROM g)
         THEN b.best_model ELSE 'SEASONAL_NAIVE' END AS champion_model,
    CASE WHEN b.best_model <> 'SEASONAL_NAIVE'
              AND (n.naive_wmae - b.best_wmae)/NULLIF(n.naive_wmae,0)*100
                  >= (SELECT naive_guardrail_pct FROM g)
         THEN b.best_wmae ELSE n.naive_wmae END AS champion_wmae,
    CURRENT_TIMESTAMP() AS selected_at
FROM best b
JOIN naive n USING (series_key)
LEFT JOIN runner r USING (series_key);

-- Natural-language rationale per series (deterministic templating over the numbers
-- + characteristics). Indexed by Cortex Search so the agent can explain "why".
CREATE OR REPLACE TABLE SERIES_RATIONALE AS
SELECT
    c.series_key,
    'Model choice for ' || c.series_key || ' (Store ' || ch.store || ', Type ' || ch.store_type
        || ', Dept ' || ch.dept || ')' AS title,
    ch.store, ch.store_type, ch.dept, ch.sb_class,
    cs.champion_model, cs.champion_wmae, cs.naive_wmae, cs.best_impr_pct, cs.runner_up,
    'Series ' || c.series_key || ' is a ' || ch.sb_class || ' department (Store ' || ch.store
      || ', Type ' || ch.store_type || ', Dept ' || ch.dept || ') with '
      || CASE WHEN ch.seas_strength>=0.9 THEN 'strong' WHEN ch.seas_strength>=0.75 THEN 'moderate' ELSE 'weak' END
      || ' yearly seasonality (strength ' || ch.seas_strength || ') and '
      || CASE WHEN ch.holiday_lift>=1.5 THEN 'strong' WHEN ch.holiday_lift>=1.1 THEN 'mild'
              WHEN ch.holiday_lift>=0.9 THEN 'neutral' ELSE 'negative' END
      || ' holiday sensitivity (holiday lift ' || ch.holiday_lift || 'x). '
      || 'In rolling-origin backtesting the champion model is ' || cs.champion_model
      || ' with a holiday-weighted error (WMAE) of ' || cs.champion_wmae || ', '
      || CASE WHEN cs.champion_model='SEASONAL_NAIVE'
              THEN 'because no candidate model beat the seasonal-naive baseline by the required margin, so the robust baseline is deployed.'
              ELSE 'beating seasonal-naive by ' || cs.best_impr_pct || '% (runner-up: ' || COALESCE(cs.runner_up,'n/a') || '). '
                   || CASE cs.champion_model
                        WHEN 'SARIMA'  THEN 'SARIMA wins here because the series has strong autocorrelation and a clean seasonal cycle it can exploit.'
                        WHEN 'PROPHET' THEN 'Prophet wins here because pronounced holiday effects are captured well by its holiday regressors.'
                        WHEN 'GBM'     THEN 'The gradient-boosting model wins here by exploiting nonlinear relationships with exogenous drivers (temperature, fuel price, CPI, unemployment, markdowns).'
                        WHEN 'SNOWFLAKE_GBM_NATIVE' THEN 'Snowflake''s native forecaster wins here, exploiting the exogenous drivers with automated seasonality handling.'
                        ELSE '' END
         END AS body
FROM SERIES_CHARACTERISTICS c
JOIN SERIES_CHARACTERISTICS ch ON ch.series_key = c.series_key
JOIN CHAMPION_SELECTION cs ON cs.series_key = c.series_key
WHERE c.is_demo;

-- Summary
SELECT champion_model, COUNT(*) series, ROUND(AVG(best_impr_pct),1) avg_impr_vs_naive_pct
FROM CHAMPION_SELECTION GROUP BY 1 ORDER BY 2 DESC;

/* Next: 06_future_forecasts.sql */
