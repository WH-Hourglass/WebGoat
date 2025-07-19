//수정중  8, project uuid 넘기는 부분 추가 -> 했다가 다시 제거 
// 테스트용, check_cvss_and_notify_1.py 호출 ver
// [DEBUG] 메시지는 향후 모두 삭제 예정 
// upload_sbom1.sh 내용 반영 

#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 로그 파일 경로 (임시) 
LOG_FILE="/tmp/functions.log"

# 로그 기록 예시 (임시) 
echo "CVSS 점검 시작: $(date)" >> $CVSS_LOG_FILE


# 로그 함수 정의 (임시) 
log_message() {
    local MESSAGE="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $MESSAGE" >> $LOG_FILE
}


# Java 버전 탐지 함수
detect_java_version() {
    local REPO_NAME="$1"
    local VERSION="$2"

    echo "[+] 언어 및 Java 버전 탐지 시작"
    cd "/tmp/${REPO_NAME}_${BUILD_ID}" || exit 1

    IMAGE_TAG="cli"
    JAVA_VERSION=""
    BUILD_FILE=""

    if [[ -f "pom.xml" ]]; then
        echo "[🔍] pom.xml 감지됨 – Java Maven 프로젝트"
        BUILD_FILE="pom.xml"
    elif [[ -f "build.gradle.kts" ]]; then
        echo "[🔍] build.gradle.kts 감지됨 – Java Gradle(Kotlin DSL) 프로젝트"
        BUILD_FILE="build.gradle.kts"
    elif [[ -f "build.gradle" ]]; then
        echo "[🔍] build.gradle 감지됨 – Java Gradle 프로젝트"
        BUILD_FILE="build.gradle"
    fi

    if [[ -n "$BUILD_FILE" ]]; then
        JAVA_VERSION=$(python3 "$SCRIPT_DIR/pom_to_docker_image.py" "$BUILD_FILE" 2>/dev/null | tr -d '\r')
        if [[ -z "$JAVA_VERSION" ]]; then
            echo "[⚠️] Bedrock 기반 감지 실패 – 기본 java 사용"
            IMAGE_TAG="java"
        else
            echo "[✅] 감지된 Java 버전: $JAVA_VERSION"
            IMAGE_TAG=$(python3 "$SCRIPT_DIR/docker_tag.py" "$JAVA_VERSION" 2>/dev/null | tr -d '\r')
            [[ -z "$IMAGE_TAG" ]] && IMAGE_TAG="java"
        fi
    elif [[ -f "package.json" || -f "requirements.txt" || -f "pyproject.toml" || -f "go.mod" || -f "Cargo.toml" ]]; then
        echo "[ℹ️] Java 외 언어 프로젝트 감지됨 – CLI 이미지 사용"
        IMAGE_TAG="cli"
        JAVA_VERSION="Not_Java"
    else
        echo "[⚠️] 지원되는 빌드 파일을 감지하지 못함 – 기본(cli) 사용"
        IMAGE_TAG="cli"
        JAVA_VERSION="UNKNOWN"
    fi

    echo "[ℹ️] 최종 선택된 Docker 이미지 태그: $IMAGE_TAG"
    echo "$IMAGE_TAG" > "/tmp/cdxgen_image_tag_${REPO_NAME}_${VERSION}.txt"
    echo "$JAVA_VERSION" > "/tmp/cdxgen_java_version_${REPO_NAME}_${VERSION}.txt"
}


# CVSS 점검 함수
#check_cvss() {
 #   local PROJECT_UUID="$1"
  #  local DT_API_KEY="$2"
   # local DT_URL="$3"
    #local REPO_NAME="$4"

    #log_message "[+] CVSS 점검 시작 - PROJECT_UUID: $PROJECT_UUID, REPO_NAME: $REPO_NAME"
    
    #if [[ -z "$PROJECT_UUID" || -z "$DT_API_KEY" || -z "$DT_URL" || -z "$REPO_NAME" ]]; then
     #   log_message "[⚠️] CVSS 점검을 위한 필수 매개변수가 누락됨"
      #  return 1
    #fi
    
    # python3 호출은 upload_sbom에서 이미 처리되므로 이 부분은 제거
    #log_message "[✅] CVSS 점검을 위한 준비가 완료되었습니다."
    #return 0
#} 

# SBOM 업로드 함수
upload_sbom() {
    local REPO_NAME="$1"
    local VERSION="$2"
    local REPO_DIR="$3"
    local COMMIT_ID="$4"

    local SBOM_FILE="${REPO_DIR}/sbom_${REPO_NAME}_${VERSION}.json"
    local PROJECT_VERSION="${VERSION}_$(date +%Y%m%d_%H%M%S)"

    log_message "🚀 SBOM 업로드 시작: $SBOM_FILE (projectVersion: $PROJECT_VERSION)"

    curl -s -X POST "$DT_URL/api/v1/bom" \
        -H "X-Api-Key: $DT_API_KEY" \
        -F "projectName=$REPO_NAME" \
        -F "projectVersion=$PROJECT_VERSION" \
        -F "bom=@$SBOM_FILE" \
        -F "autoCreate=true" >/dev/null

    log_message "[⏳] 프로젝트 UUID 조회 대기..."
    sleep 5

    local PROJECT_UUID=$(curl -s -X GET "$DT_URL/api/v1/project?name=${REPO_NAME}&version=${PROJECT_VERSION}" \
        -H "X-Api-Key: $DT_API_KEY" | jq -r '.[0].uuid')

    if [[ -z "$PROJECT_UUID" || "$PROJECT_UUID" == "null" ]]; then
        log_message "❌ 프로젝트 UUID를 찾을 수 없습니다."
        return 1
    fi

    log_message "✅ UUID 조회 성공: $PROJECT_UUID"

    sleep 20  # 분석 대기

    check_cvss "$PROJECT_UUID" "$REPO_NAME" "$PROJECT_VERSION"
}

check_cvss() {
    local PROJECT_UUID="$1"
    local REPO_NAME="$2"
    local PROJECT_VERSION="$3"

    local METRICS=$(curl -s -X GET "$DT_URL/api/v1/metrics/project/${PROJECT_UUID}/current" -H "X-Api-Key: $DT_API_KEY")
    local VULNS=$(curl -s -X GET "$DT_URL/api/v1/vulnerability/project/${PROJECT_UUID}" -H "X-Api-Key: $DT_API_KEY")

    local CVSS9_VULNS=$(echo "$VULNS" | jq '[.[] | select(
        (.cvssV3.baseScore // .cvssV2.baseScore // 0) >= 9
    )]')

    local COUNT=$(echo "$CVSS9_VULNS" | jq 'length')
    local SUMMARY="*정책 결과:*"
    local EXIT_CODE=0

    if [[ "$COUNT" -gt 0 ]]; then
        SUMMARY+=" ❌ *정책 위반* - CVSS 9 이상 $COUNT건"
        EXIT_CODE=2
    else
        SUMMARY+=" ✅ *통과* - CVSS 9 이상 없음"
    fi

    local CRITICAL=$(echo "$METRICS" | jq '.critical // 0')
    local HIGH=$(echo "$METRICS" | jq '.high // 0')
    local MEDIUM=$(echo "$METRICS" | jq '.medium // 0')
    local LOW=$(echo "$METRICS" | jq '.low // 0')

    local MESSAGE="*${REPO_NAME} (${PROJECT_VERSION})*\n${SUMMARY}\n\n• Critical: $CRITICAL\n• High: $HIGH\n• Medium: $MEDIUM\n• Low: $LOW\n• CVSS ≥ 9: $COUNT"

    if [[ -n "$SLACK_WEBHOOK_URL" ]]; then
        curl -X POST "$SLACK_WEBHOOK_URL" \
            -H 'Content-Type: application/json' \
            -d "{\"text\": \"$MESSAGE\"}"
        log_message "✅ Slack 전송 완료"
    fi

    return $EXIT_CODE
}



