#!/bin/bash
set -eo pipefail 

set -o allexport
set +o allexport

if [ -z "$DYNAMIC_IMAGE_TAG" ]; then
  echo "Error: Dynamic IMAGE_TAG not provided as an argument to docker_build.sh."
  echo "Usage: docker_build.sh <DYNAMIC_IMAGE_TAG>"
  exit 1
fi

FULL_IMAGE_NAME_WITH_TAG="${ECR_REPO}:${DYNAMIC_IMAGE_TAG}"

echo "Building Docker image: ${FULL_IMAGE_NAME_WITH_TAG}"
docker build -t "${FULL_IMAGE_NAME_WITH_TAG}" .

echo "Docker image ${FULL_IMAGE_NAME_WITH_TAG} built successfully."
