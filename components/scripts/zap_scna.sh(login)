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
LOGIN_URL="${5:-/WebGoat/login"}
echo "[*] ZAP 스캔 대상: $TARGET_URL"

# 로그인 관련 설정
USERNAME="${6:-test12}"
PASSWORD="${7:-test12}"
COOKIE_TXT="${CONTAINER_NAME}_cookie.txt"

# 리포트 설정

echo "============================================="
echo "ZAP 보안 스캔 시작 (로그인 기능 포함)"
echo "컨테이너: $CONTAINER_NAME"
echo "사용자명: $USERNAME"
echo "시작 경로: $START_PATH"
echo "============================================="



# ② 애플리케이션 준비 대기 (WebGoat 전용 로그인 페이지 체크)
echo "[2] 초기 대기 15초..."
sleep 15

echo "[2-1] 로그인 페이지 준비 확인 시작..."
for i in $(seq 1 10); do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${HOST}${LOGIN_URL}")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "[+] 로그인 페이지 준비 완료!"
        break
    else
        echo "    [$i] 준비 안됨 (HTTP $HTTP_CODE). 10초 후 재시도..."
        sleep 10
    fi
done

if [ "$HTTP_CODE" != "200" ]; then
    echo "[-] 로그인 페이지가 10회 재시도 후에도 준비되지 않았습니다."
    exit 1
fi

# ③ 회원가입 → 로그인
echo "[3] 회원가입 요청..."
curl -s -i -c "$COOKIE_TXT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$USERNAME&password=$PASSWORD&matchingPassword=$PASSWORD&agree=agree" \
    "${HOST}${LOGIN_URL}${" > /dev/null

echo "[3-1] 로그인 시도..."
curl -s -i -c "$COOKIE_TXT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "username=$USERNAME&password=$PASSWORD" \
    "${HOST}${LOGIN_URL}" > /dev/null

# 쿠키 확인
COOKIE=$(grep JSESSIONID "$COOKIE_TXT" | awk '{print $7}')
if [ -n "$COOKIE" ]; then
    echo "[+] 로그인 성공 - 쿠키: $COOKIE"
else
    echo "[-] 로그인 실패"
    exit 1
fi


# ⑥ 인증 쿠키 설정 & 초기 페이지 접근
echo "[5] ZAP에 인증 쿠키 설정..."
curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/replacer/action/addRule/?description=authcookie&enabled=true&matchType=REQ_HEADER&matchRegex=false&matchString=Cookie&replacement=JSESSIONID=$COOKIE" > /dev/null

echo "[5-1] 인증 페이지 접근..."
curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/core/action/accessUrl/?url=${TARGET_URL}" > /dev/null

# ⑦ Spider 스캔
echo "[6] Spider 스캔 시작..."
SPIDER_ID=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/spider/action/scan/?url=${TARGET_URL}" | jq -r .scan)
while true; do
    STATUS=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/spider/view/status/?scanId=$SPIDER_ID" | jq -r .status)
    echo "  - Spider 진행률: $STATUS%"
    [ "$STATUS" == "100" ] && break
    sleep 2
done

# ⑧ Active 스캔
echo "[7] Active 스캔 시작..."
SCAN_ID=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/ascan/action/scan/?url=${TARGET_URL}" | jq -r .scan)
while true; do
    STATUS=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/ascan/view/status/?scanId=$SCAN_ID" | jq -r .status)
    echo "  - Active 진행률: $STATUS%"
    [ "$STATUS" == "100" ] && break
    sleep 5
done

# ⑨ Passive 스캔 대기
echo "[7-1] Passive 스캔 대기 중..."
while true; do
    REMAIN=$(curl -s "http://$ZAP_HOST:$ZAP_PORT/JSON/pscan/view/recordsToScan/" | jq -r .recordsToScan)
    echo "  - 남은 레코드: $REMAIN"
    [ "$REMAIN" -eq 0 ] && break
    sleep 2
done

# ⑪ JSON 리포트 저장
echo "[8-1] JSON 리포트 저장..."
curl -s "http://$ZAP_HOST:$ZAP_PORT/OTHER/core/other/jsonreport/" -o "$REPORT_JSON"
if [ -s "$REPORT_JSON" ]; then
    echo "[+] 리포트: $REPORT_JSON"
else
    echo "[-] 리포트 생성 실패"
    exit 1
fi

# ⑫ ZAP 프로세스 정리
echo "[9] ZAP 프로세스 정리..."
pkill -f zap.sh || true

# 종료 및 수행 시간 출력
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
printf "[+] 전체 수행 시간: %d분 %d초\n" $((ELAPSED/60)) $((ELAPSED%60))


# 임시 파일 정리
rm -f "${CONTAINER_NAME}_cookie.txt"
