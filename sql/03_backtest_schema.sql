USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WALMART_WH;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

-- Backtest configuration (single row; edit to re-parameterise the harness).
CREATE OR REPLACE TABLE BACKTEST_CONFIG (
    horizon_weeks      NUMBER  DEFAULT 8,      -- forecast horizon per origin
    origins            ARRAY   DEFAULT [24,16,8],  -- weeks-from-end for each rolling origin
    naive_guardrail_pct NUMBER DEFAULT 2.0,    -- champion must beat seasonal-naive by >= this %
    interval_z         FLOAT   DEFAULT 1.28    -- ~80% prediction interval (residual-based)
);
INSERT INTO BACKTEST_CONFIG (horizon_weeks, origins, naive_guardrail_pct, interval_z)
    SELECT 8, [24,16,8], 2.0, 1.28;

-- Per-origin backtest predictions (one row per series x model x origin x step).
CREATE OR REPLACE TABLE BACKTEST_FORECASTS (
    run_id       VARCHAR,
    model        VARCHAR,       -- SEASONAL_NAIVE | SARIMA | PROPHET | GBM | SNOWFLAKE_GBM_NATIVE
    series_key   VARCHAR,
    origin_date  DATE,          -- last training week for this origin
    target_week  DATE,
    horizon_step NUMBER,
    y_true       FLOAT,
    y_pred       FLOAT,
    is_holiday   BOOLEAN,
    created_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Forward (out-of-sample) forecast per series x model, fit on full history.
CREATE OR REPLACE TABLE FORWARD_RAW (
    run_id       VARCHAR,
    model        VARCHAR,
    series_key   VARCHAR,
    target_week  DATE,
    horizon_step NUMBER,
    y_pred       FLOAT,
    y_lower      FLOAT,
    y_upper      FLOAT,
    created_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Run registry.
CREATE OR REPLACE TABLE MODEL_RUNS (
    run_id     VARCHAR,
    engine     VARCHAR,        -- SNOWPARK | NATIVE_MLFORECAST
    note       VARCHAR,
    started_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

/* Next: 04_snowpark_models.sql */
