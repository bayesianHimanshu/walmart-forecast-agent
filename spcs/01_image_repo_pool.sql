USE ROLE ACCOUNTADMIN;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

-- Image repository (OCIv2 registry inside your account).
CREATE IMAGE REPOSITORY IF NOT EXISTS WALMART_DEMO.FORECAST.IMAGES;

-- Show the repository URL you'll docker-push to (copy the repository_url).
SHOW IMAGE REPOSITORIES IN SCHEMA WALMART_DEMO.FORECAST;

-- Compute pool that runs the container.
CREATE COMPUTE POOL IF NOT EXISTS WALMART_UI_POOL
  MIN_NODES = 1
  MAX_NODES = 1
  INSTANCE_FAMILY = CPU_X64_XS
  AUTO_RESUME = TRUE
  COMMENT = 'Runs the Walmart forecast Next.js UI';

-- The service's owner role needs to bind a public endpoint and read the data.
-- (Using ACCOUNTADMIN as owner here for simplicity; in production use a dedicated role.)
GRANT BIND SERVICE ENDPOINT ON ACCOUNT TO ROLE ACCOUNTADMIN;

-- Optional egress: only needed if the container must reach the public internet.
-- The UI talks to Snowflake over the internal session token, so egress is NOT
-- required for the agent. Left here commented for reference.
CREATE OR REPLACE NETWORK RULE WALMART_EGRESS
  TYPE = 'HOST_PORT' MODE = 'EGRESS' VALUE_LIST = ('0.0.0.0:443','0.0.0.0:80');
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION WALMART_EAI
  ALLOWED_NETWORK_RULES = (WALMART_EGRESS) ENABLED = TRUE;

/* Next: build & push the image (build_and_push.sh), then 02_create_service.sql */
