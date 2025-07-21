#!/bin/bash

if [ -z "$DYNAMIC_IMAGE_TAG" ]; then
  echo "Error: IMAGE_TAG not provided as an argument."
  exit 1
fi

echo "Pushing image: $ECR_REPO:$DYNAMIC_IMAGE_TAG"
docker push "$ECR_REPO:$DYNAMIC_IMAGE_TAG"

echo "Image pushed successfully!"
