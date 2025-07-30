#!/bin/bash
set -e

# 배포 상태 확인 함수
check_active_deployment() {
  local status
  status=$(aws deploy get-deployment-group \
    --application-name "$DEPLOY_APP" \
    --deployment-group-name "$DEPLOY_GROUP" \
    --region "$REGION" \
    --query 'deploymentGroupInfo.lastAttemptedDeployment.status' \
    --output text 2>/dev/null)

  echo "$status"
}

# 최대 대기 시간 (초)
MAX_WAIT_SECONDS=3600  # 60분
WAIT_INTERVAL=10
elapsed=0

echo "[*] 기존 배포 상태 확인 중..."
while true; do
  status=$(check_active_deployment)

  if [[ "$status" == "InProgress" || "$status" == "Created" ]]; then
    if (( elapsed >= MAX_WAIT_SECONDS )); then
      echo "⏰ 최대 대기 시간 초과. 배포 중단."
      exit 1
    fi

    echo "⏳ 현재 상태: $status → 대기 중... (${elapsed}s)"
    sleep "$WAIT_INTERVAL"
    ((elapsed += WAIT_INTERVAL))
  else
    echo "✅ 이전 배포 완료 상태 확인: $status"
    break
  fi
done

# 번들 업로드
echo "[*] 배포 번들 S3 업로드 중..."
aws s3 cp "$BUNDLE" "s3://$S3_BUCKET/$BUNDLE" --region "$REGION"

# CodeDeploy 배포 시작
echo "[*] CodeDeploy 배포 시작"
aws deploy create-deployment \
    --application-name "$DEPLOY_APP" \
    --deployment-group-name "$DEPLOY_GROUP" \
    --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
    --s3-location bucket="$S3_BUCKET",bundleType=zip,key="$BUNDLE" \
    --region "$REGION"

echo "🚀 배포 요청 완료"
