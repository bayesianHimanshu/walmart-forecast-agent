USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WALMART_WH;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

-- ----------------------------------------------------------------------------
-- Per-series summary, and a denormalized series x week analytics fact.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE SERIES_SUMMARY AS
SELECT c.series_key, c.store, c.dept, c.store_type, c.sb_class,
       c.seas_strength, c.holiday_lift, c.mean_sales,
       cs.champion_model, cs.champion_wmae, cs.naive_wmae, cs.best_impr_pct, cs.runner_up
FROM SERIES_CHARACTERISTICS c
JOIN CHAMPION_SELECTION cs USING (series_key)
WHERE c.is_demo;

CREATE OR REPLACE TABLE FORECAST_ANALYTICS AS
SELECT
    ROW_NUMBER() OVER (ORDER BY s.series_key, f.target_week) AS row_id,
    s.series_key, s.store, s.dept, s.store_type, s.sb_class,
    s.seas_strength, s.holiday_lift, s.mean_sales,
    s.champion_model, s.champion_wmae, s.naive_wmae, s.best_impr_pct,
    f.target_week, f.horizon_step, f.forecast, f.lower_80, f.upper_80
FROM SERIES_SUMMARY s
JOIN FUTURE_FORECASTS f USING (series_key);

-- ----------------------------------------------------------------------------
-- Semantic view (single table -> lowest-risk, no relationships needed).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW WALMART_FORECAST_SV
  TABLES (
    fa AS WALMART_DEMO.FORECAST.FORECAST_ANALYTICS
      PRIMARY KEY (row_id)
      COMMENT = 'Per store-department, per forecast-week analytics: the deployed 8-week forecast plus the champion model and each series'' characteristics'
  )
  DIMENSIONS (
    fa.series_key     AS series_key     COMMENT = 'Series identifier, e.g. S20_D92 = Store 20 Department 92',
    fa.store          AS store          COMMENT = 'Store number (10, 20, 37)',
    fa.dept           AS dept           COMMENT = 'Department number',
    fa.store_type     AS store_type     COMMENT = 'Store type: A (large), B (mid), C (small)',
    fa.sb_class       AS sb_class       COMMENT = 'Demand class: smooth or erratic',
    fa.champion_model AS champion_model COMMENT = 'The model deployed for this series: SEASONAL_NAIVE, SARIMA, PROPHET, GBM, or SNOWFLAKE_GBM_NATIVE',
    fa.target_week    AS target_week    COMMENT = 'Week the forecast is for',
    fa.horizon_step   AS horizon_step   COMMENT = 'Weeks ahead (1-8)'
  )
  METRICS (
    fa.series_count       AS COUNT(DISTINCT series_key)  COMMENT = 'Number of series',
    fa.total_forecast     AS SUM(forecast)               COMMENT = 'Total forecasted weekly sales (USD)',
    fa.avg_forecast       AS AVG(forecast)               COMMENT = 'Average forecasted weekly sales (USD)',
    fa.avg_seasonality    AS AVG(seas_strength)          COMMENT = 'Average yearly-seasonality strength (0-1)',
    fa.avg_holiday_lift   AS AVG(holiday_lift)           COMMENT = 'Average holiday sales lift (multiple of normal weeks)',
    fa.avg_weekly_sales   AS AVG(mean_sales)             COMMENT = 'Average historical weekly sales (USD)',
    fa.avg_champion_wmae  AS AVG(champion_wmae)          COMMENT = 'Average champion backtest error (holiday-weighted MAE)',
    fa.avg_improvement    AS AVG(best_impr_pct)          COMMENT = 'Average % the champion beats seasonal-naive'
  )
  COMMENT = 'Walmart demand forecasts, champion models, and series characteristics for the demo subset';

-- quick check
SELECT * FROM SEMANTIC_VIEW(WALMART_FORECAST_SV METRICS series_count, avg_improvement DIMENSIONS champion_model)
ORDER BY series_count DESC;

-- ----------------------------------------------------------------------------
-- Documents for Cortex Search: per-series rationales + methodology notes.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE TABLE MODEL_DOCS (
    doc_id NUMBER AUTOINCREMENT, doc_type VARCHAR, series_key VARCHAR, title VARCHAR, body VARCHAR
);

INSERT INTO MODEL_DOCS (doc_type, series_key, title, body)
SELECT 'rationale', series_key, title, body FROM SERIES_RATIONALE;

INSERT INTO MODEL_DOCS (doc_type, series_key, title, body) VALUES
('methodology', NULL, 'How model selection works',
 'For every store-department series we run four forecasting models: seasonal-naive (a baseline that repeats the value from 52 weeks earlier), SARIMA (a seasonal statistical model), Prophet (an additive model with explicit holiday regressors), and a gradient-boosting model (GBM) that uses lags plus exogenous drivers. Snowflake''s native ML.FORECAST can also compete. Each model is evaluated with rolling-origin backtesting: we hold out successive 8-week windows, forecast them, and measure error. The champion is the model with the lowest holiday-weighted error, and it must beat the seasonal-naive baseline by a set margin or the baseline is deployed instead. Selection is deterministic and auditable; the agent explains it but does not make the statistical choice.'),
('methodology', NULL, 'What WMAE, MASE and sMAPE mean',
 'WMAE (weighted mean absolute error) is the primary metric: absolute forecast errors averaged with holiday weeks weighted five times heavier, matching the Walmart competition scoring, so accuracy on high-stakes holiday weeks counts most. MASE (mean absolute scaled error) scales error by a seasonal-naive benchmark so it is comparable across series of different sizes; below 1 means better than the naive benchmark. sMAPE is a symmetric percentage error for intuitive interpretation. We report all three but select the champion on WMAE.'),
('methodology', NULL, 'Which model tends to win where',
 'SARIMA tends to win on smooth, strongly seasonal, high-volume departments with clean autocorrelation. Prophet tends to win where holiday spikes dominate (high holiday lift). The gradient-boosting model tends to win where exogenous drivers such as temperature, fuel price, CPI, unemployment, or markdowns carry signal and relationships are nonlinear. Seasonal-naive is retained where no model beats the baseline by the required margin, which is common for low-signal or highly erratic departments.');

CREATE OR REPLACE CORTEX SEARCH SERVICE MODEL_DOCS_SEARCH
  ON body
  ATTRIBUTES doc_type, series_key, title
  WAREHOUSE = WALMART_WH
  TARGET_LAG = '1 hour'
  AS (SELECT doc_id, doc_type, series_key, title, body FROM MODEL_DOCS);

-- ----------------------------------------------------------------------------
-- The agent.  model 'auto' -> Snowflake picks the best available model.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE AGENT WALMART_FORECAST_AGENT
  COMMENT = 'Demand-forecasting analyst for Walmart store-department sales: explains forecasts, champion models, accuracy, and recommendations.'
  FROM SPECIFICATION $$
models:
  orchestration: auto
orchestration:
  budget:
    seconds: 60
    tokens: 32000
instructions:
  system: "You are a demand-forecasting analyst for a Walmart-style retailer. You help planners understand the 8-week sales forecast for each store-department series, which model is deployed for each series and why, how accurate it has been, and what actions the numbers imply. Sales and forecasts are weekly, in US dollars. A series key like S20_D92 means Store 20, Department 92."
  orchestration: "Use the Forecasts tool (Cortex Analyst) for anything quantitative: forecast values by week, totals, rankings, accuracy (WMAE/improvement), champion models, seasonality, holiday lift, and comparisons across store, department, store type, or demand class. Use the Rationale tool (Cortex Search) for qualitative questions: why a particular model was chosen for a series, how the model-selection process works, or what WMAE/MASE/sMAPE mean. When a question needs both the numbers and the reasoning (for example, 'what's the forecast for Store 20 Dept 92 and why that model'), use both tools and combine them."
  response: "Answer like an analyst briefing a planner. Lead with the direct answer and key figures, then a short 'why'. Format money with $ and thousands separators, percentages to one decimal. Use a compact table for multi-week forecasts or multi-series comparisons. When useful, translate a forecast into a recommendation (e.g. expected uplift into a holiday week suggests building stock). Be concise."
tools:
  - tool_spec:
      type: "cortex_analyst_text_to_sql"
      name: "Forecasts"
      description: "Quantitative questions about Walmart demand forecasts, champion models, accuracy, and series characteristics."
  - tool_spec:
      type: "cortex_search"
      name: "Rationale"
      description: "Explanations of why each series' model was chosen and how the forecasting methodology and metrics work."
tool_resources:
  Forecasts:
    semantic_view: "WALMART_DEMO.FORECAST.WALMART_FORECAST_SV"
    execution_environment:
      type: "warehouse"
      warehouse: "WALMART_WH"
  Rationale:
    name: "WALMART_DEMO.FORECAST.MODEL_DOCS_SEARCH"
    max_results: "4"
$$;

SHOW AGENTS;

-- Optional smoke test:
-- SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
--   'WALMART_DEMO.FORECAST.WALMART_FORECAST_AGENT',
--   $${"messages":[{"role":"user","content":[{"type":"text","text":"What's the 8-week forecast for Store 20 Dept 92, which model, and why?"}]}]}$$);

/* Next: deploy the UI — see ../spcs/ and ../app/ */
