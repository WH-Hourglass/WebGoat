#!/bin/bash

START_TIME=$(date +%s)

# ⛳ 인자로 컨테이너명과 시작 경로를 받음
webapp_CONTAINER="${1:-containername}" # webgoat, vulnapp
ZAP_PORT="${2:-8090}"
START_PATH="${3:-/}"  # ex: /webgoat/start.mvc
WEBAPP_HOST_PORT="${4:-8081}" # zap에 넘겨줄 외부포트 변수
ZAP_HOST="127.0.0.1"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_JSON="$HOME/zap_${webapp_CONTAINER}.json"
HOST="http://127.0.0.1:${WEBAPP_HOST_PORT}"
TARGET_URL="${HOST}${START_PATH}"
echo "[*] ZAP 스캔 대상: $TARGET_URL"

# Spider 스캔
echo "[1] Spider 스캔 시작..."
SPIDER_ID=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/spider/action/scan/?url=${TARGET_URL}" | jq -r .scan)
while true; do
  STATUS=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/spider/view/status/?scanId=$SPIDER_ID" | jq -r .status)
  echo "  - Spider 진행률: $STATUS%"
  [ "$STATUS" == "100" ] && break
  sleep 2
done

# Active 스캔
echo "[2] Active 스캔 시작..."
SCAN_ID=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/ascan/action/scan/?url=${TARGET_URL}" | jq -r .scan)
while true; do
  STATUS=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/ascan/view/status/?scanId=$SCAN_ID" | jq -r .status)
  echo "  - Active 진행률: $STATUS%"
  [ "$STATUS" == "100" ] && break
  sleep 5
done

# Passive 스캔 대기
echo "[2-1] Passive 스캔 대기 중..."
while true; do
  REMAIN=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/pscan/view/recordsToScan/" | jq -r .recordsToScan)
  echo "  - 남은 레코드: $REMAIN"
  [ "$REMAIN" -eq 0 ] && break
  sleep 2
done
# HTML 리포트 저장
echo "[3] HTML 리포트 저장..."
HTML_REPORT="$HOME/zap_report_${TIMESTAMP}.html"
curl -s "http://$ZAP_HOST:$ZAP_PORT/OTHER/core/other/htmlreport/" -o "$HTML_REPORT"

if [ -s "$HTML_REPORT" ]; then
  echo "[+] HTML 리포트: $HTML_REPORT"
else
  echo "[-] HTML 리포트 생성 실패"
  exit 1
fi
# JSON 리포트 저장
echo "[4] JSON 리포트 저장..."
curl -s "http://$ZAP_HOST:$ZAP_PORT/OTHER/core/other/jsonreport/" -o "$REPORT_JSON"
if [ -s "$REPORT_JSON" ]; then
  echo "[+] 리포트: $REPORT_JSON"
else
  echo "[-] 리포트 생성 실패"
  exit 1
fi

# 종료 및 수행 시간 출력
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
printf "[+] 전체 수행 시간: %d분 %d초\n" $((ELAPSED/60)) $((ELAPSED%60))
