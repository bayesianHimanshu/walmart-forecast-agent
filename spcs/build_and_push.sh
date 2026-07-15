#!/usr/bin/env bash
# Build the Next.js image (linux/amd64) and push it to your Snowflake image repo.
#
# 1) Get your repo URL:
#      SHOW IMAGE REPOSITORIES IN SCHEMA WALMART_DEMO.FORECAST;   -- copy repository_url
# 2) Export it and run this script from the repo root:
#      export SNOW_REPO="<org>-<account>.registry.snowflakecomputing.com/walmart_demo/forecast/images"
#      export SNOW_REGISTRY="<org>-<account>.registry.snowflakecomputing.com"
#      export SNOW_USER="<your_user>"
#      bash spcs/build_and_push.sh
set -euo pipefail

: "${SNOW_REPO:?set SNOW_REPO to your image repository URL (no trailing slash)}"
: "${SNOW_REGISTRY:?set SNOW_REGISTRY to <org>-<account>.registry.snowflakecomputing.com}"
: "${SNOW_USER:?set SNOW_USER to your Snowflake username}"
IMAGE="${SNOW_REPO}/forecast-ui:latest"

echo "Logging in to $SNOW_REGISTRY ..."
# You'll be prompted for your Snowflake password (or use: snow spcs image-registry login)
docker login "$SNOW_REGISTRY" -u "$SNOW_USER"

echo "Building $IMAGE (linux/amd64) ..."
docker build --platform linux/amd64 -t "$IMAGE" ./app

echo "Pushing $IMAGE ..."
docker push "$IMAGE"

echo "Done. Now run spcs/02_create_service.sql (it references this image tag)."
