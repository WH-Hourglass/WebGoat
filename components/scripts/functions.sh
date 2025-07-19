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

    if [[ -z "$REPO_NAME" || -z "$VERSION" || -z "$REPO_DIR" || -z "$COMMIT_ID" ]]; then
        log_message "❌ upload_sbom 함수 호출 시 REPO_NAME, VERSION, REPO_DIR, COMMIT_ID가 필요합니다."
        return 1
    fi

    source /home/ec2-user/.env

    local SBOM_FILE="${REPO_DIR}/sbom_${REPO_NAME}_${VERSION}.json"
    if [[ ! -f "$SBOM_FILE" ]]; then
        log_message "❌ SBOM 파일이 존재하지 않습니다: $SBOM_FILE"
        return 1
    fi

    local PROJECT_VERSION="$VERSION"
    log_message "🚀 SBOM 업로드 시작: $SBOM_FILE (projectVersion: $PROJECT_VERSION)"

    # SBOM 업로드
    log_message "[🔍] SBOM 업로드 실행 중..."
    local upload_response=$(curl -s -X POST http://localhost:8080/api/v1/bom \
        -H "X-Api-Key: $DT_API_KEY" \
        -F "projectName=$REPO_NAME" \
        -F "projectVersion=$PROJECT_VERSION" \
        -F "bom=@$SBOM_FILE" \
        -F "autoCreate=true" 2>&1)
        
    local curl_exit_code=$?
    log_message "[ℹ️] CURL 종료 코드: $curl_exit_code"
    
    if [[ $curl_exit_code -ne 0 ]]; then
        log_message "❌ SBOM 업로드 실패"
        return 1
    fi

    log_message "[DEBUG] 업로드 완료, 다음 단계 시작"
    
    # 업로드 후 분석 완료까지 대기 (더 긴 대기 시간)
    log_message "[⏳] Dependency-Track 분석 완료까지 대기 중..."
    sleep 30
}

check_cvss() {
    local REPO_NAME="$1"
    local PROJECT_VERSION="$2"

    # 환경변수 로드 (Jenkins에서는 꼭 필요)
    source /home/ec2-user/.env

    # DEBUG 로그
    log_message "[+] check_cvss_and_notify 호출: $REPO_NAME $PROJECT_VERSION"
    log_message "[DEBUG] 실행 명령: python3 /home/ec2-user/check_cvss_and_notify_2.py \"$REPO_NAME\" \"$PROJECT_VERSION\" \"$DT_API_KEY\" \"$DT_URL\""

    # Python 실행
    python3 /home/ec2-user/check_cvss_and_notify_2.py "$REPO_NAME" "$PROJECT_VERSION" "$DT_API_KEY" "$DT_URL"
    local exit_code=$?

    ...
}





