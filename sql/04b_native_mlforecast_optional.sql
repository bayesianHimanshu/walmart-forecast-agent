USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WALMART_WH;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

CREATE OR REPLACE PROCEDURE RUN_NATIVE_MLFORECAST(RUN_ID STRING)
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    horizon  NUMBER;
    origins  ARRAY;
    n_weeks  NUMBER;
    off      NUMBER;
    cut      NUMBER;
    origin_d DATE;
    win_end  DATE;
    inserted NUMBER DEFAULT 0;
BEGIN
    SELECT horizon_weeks, origins INTO :horizon, :origins FROM BACKTEST_CONFIG LIMIT 1;
    SELECT COUNT(DISTINCT week_date) INTO :n_weeks FROM SALES_WEEKLY_DEMO;

    FOR i IN 0 TO ARRAY_SIZE(:origins)-1 DO
        off := :origins[i]::NUMBER;
        cut := :n_weeks - off;

        -- origin_date = last training week; win_end = last week of the horizon window
        SELECT wk INTO :origin_d FROM (
            SELECT week_date wk, ROW_NUMBER() OVER (ORDER BY week_date) rn
            FROM (SELECT DISTINCT week_date FROM SALES_WEEKLY_DEMO)
        ) WHERE rn = :cut;

        SELECT wk INTO :win_end FROM (
            SELECT week_date wk, ROW_NUMBER() OVER (ORDER BY week_date) rn
            FROM (SELECT DISTINCT week_date FROM SALES_WEEKLY_DEMO)
        ) WHERE rn = :cut + :horizon;

        -- Train on everything up to and including the origin week.
        CREATE OR REPLACE SNOWFLAKE.ML.FORECAST NATIVE_FC_MODEL(
            INPUT_DATA => TABLE(
                SELECT series_key, week_date, weekly_sales,
                       temperature, fuel_price, cpi, unemployment,
                       markdown1, markdown2, markdown3, markdown4, markdown5
                FROM SALES_WEEKLY_DEMO
                WHERE week_date <= :origin_d),
            SERIES_COLNAME    => 'series_key',
            TIMESTAMP_COLNAME => 'week_date',
            TARGET_COLNAME    => 'weekly_sales'
        );

        -- Forecast the horizon window (exogenous values supplied from the window rows).
        CALL NATIVE_FC_MODEL!FORECAST(
            INPUT_DATA => TABLE(
                SELECT series_key, week_date,
                       temperature, fuel_price, cpi, unemployment,
                       markdown1, markdown2, markdown3, markdown4, markdown5
                FROM SALES_WEEKLY_DEMO
                WHERE week_date > :origin_d AND week_date <= :win_end),
            SERIES_COLNAME    => 'series_key',
            TIMESTAMP_COLNAME => 'week_date'
        );

        -- Join predictions to actuals and append.
        INSERT INTO BACKTEST_FORECASTS
            (run_id, model, series_key, origin_date, target_week, horizon_step, y_true, y_pred, is_holiday)
        SELECT :run_id, 'SNOWFLAKE_GBM_NATIVE',
               f.series::VARCHAR, :origin_d, f.ts::DATE,
               DATEDIFF('week', :origin_d, f.ts::DATE),
               w.weekly_sales, f.forecast, w.is_holiday
        FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) f
        JOIN SALES_WEEKLY_DEMO w
          ON w.series_key = f.series::VARCHAR AND w.week_date = f.ts::DATE;

        inserted := :inserted + SQLROWCOUNT;
    END FOR;

    INSERT INTO MODEL_RUNS(run_id, engine, note)
        VALUES (:run_id, 'NATIVE_MLFORECAST', 'snowflake.ml.forecast competitor');
    RETURN 'native ML.FORECAST appended ' || :inserted || ' rows';
END;
$$;

-- Use the SAME run_id you passed to RUN_FORECAST_MODELS in 04:
-- CALL RUN_NATIVE_MLFORECAST('run_YYYYMMDD_HHMMSS');

/* Next: 05_metrics_champion_rationale.sql */
