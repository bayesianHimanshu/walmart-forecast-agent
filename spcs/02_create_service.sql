USE ROLE ACCOUNTADMIN;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

-- Option A: inline spec (simplest). Edit the image path to match your repo URL.
CREATE SERVICE IF NOT EXISTS WALMART_DEMO.FORECAST.FORECAST_UI
  IN COMPUTE POOL WALMART_UI_POOL
  FROM SPECIFICATION $$
spec:
  containers:
    - name: ui
      image: /walmart_demo/forecast/images/forecast-ui:latest
      env:
        SNOWFLAKE_WAREHOUSE: WALMART_WH
        SNOWFLAKE_DATABASE: WALMART_DEMO
        SNOWFLAKE_SCHEMA: FORECAST
        NODE_ENV: production
        PORT: "8080"
      readinessProbe:
        port: 8080
        path: /
  endpoints:
    - name: ui
      port: 8080
      public: true
$$
  MIN_INSTANCES = 1
  MAX_INSTANCES = 1
  COMMENT = 'Walmart demand-forecasting Next.js UI';

-- Watch it come up (RUNNING when ready).
SELECT SYSTEM$GET_SERVICE_STATUS('WALMART_DEMO.FORECAST.FORECAST_UI');

-- Grab the public URL (open in a browser; you'll be asked to log in to Snowflake).
SHOW ENDPOINTS IN SERVICE WALMART_DEMO.FORECAST.FORECAST_UI;

-- Logs if you need to debug the container:
SELECT SYSTEM$GET_SERVICE_LOGS('WALMART_DEMO.FORECAST.FORECAST_UI', 0, 'ui', 200);

-- Suspend the pool when you're done (public endpoints don't auto-suspend):
-- ALTER COMPUTE POOL WALMART_UI_POOL SUSPEND;
