//수정중  4
#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Java 버전 탐지 함수
detect_java_version() {
    local REPO_NAME="$1"
    local VERSION="$2"   # ← 이름 변경

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
check_cvss() {
    local PROJECT_UUID="$1"
    local DT_API_KEY="$2"
    local DT_URL="$3"
    local REPO_NAME="$4"  # 추가된 매개변수

    echo "[+] CVSS 점검 시작 - PROJECT_UUID: $PROJECT_UUID, REPO_NAME: $REPO_NAME"
    
    # Python 스크립트 실행 (상세한 로그와 함께)
    echo "[🔍] Python 스크립트 실행 중..."
    python3 /home/ec2-user/check_cvss_and_notify.py "$PROJECT_UUID" "$DT_API_KEY" "$DT_URL" "$REPO_NAME" 2>&1
    local python_exit_code=$?
    
    echo "[ℹ️] Python 스크립트 종료 코드: $python_exit_code"
    
    if [[ $python_exit_code -eq 2 ]]; then
        echo "❌ CVSS 9 이상 취약점 발견. SBOM 업로드를 중단합니다."
        return 1
    elif [[ $python_exit_code -eq 0 ]]; then
        echo "✅ CVSS 점검 통과"
        return 0
    else
        echo "⚠️ CVSS 점검 중 예상치 못한 오류 발생 (exit code: $python_exit_code)"
        return 1
    fi
}

# SBOM 업로드 함수
upload_sbom() {
    local REPO_NAME="$1"
    local VERSION="$2"
    local REPO_DIR="$3"
    local COMMIT_ID="$4"

    if [[ -z "$REPO_NAME" || -z "$VERSION" || -z "$REPO_DIR" || -z "$COMMIT_ID" ]]; then
        echo "❌ upload_sbom 함수 호출 시 REPO_NAME, VERSION, REPO_DIR, COMMIT_ID가 필요합니다."
        return 1
    fi

    source /home/ec2-user/.env

    local SBOM_FILE="${REPO_DIR}/sbom_${REPO_NAME}_${VERSION}.json"
    if [[ ! -f "$SBOM_FILE" ]]; then
        echo "❌ SBOM 파일이 존재하지 않습니다: $SBOM_FILE"
        return 1
    fi

    local PROJECT_VERSION="$VERSION"
    echo "🚀 SBOM 업로드 시작: $SBOM_FILE (projectVersion: $PROJECT_VERSION)"

    # SBOM 업로드
    echo "[🔍] SBOM 업로드 실행 중..."
    curl -X POST http://localhost:8080/api/v1/bom \
        -H "X-Api-Key: $DT_API_KEY" \
        -F "projectName=$REPO_NAME" \
        -F "projectVersion=$PROJECT_VERSION" \
        -F "bom=@$SBOM_FILE" \
        -F "autoCreate=true" 2>&1
        
    local curl_exit_code=$?
    echo "[ℹ️] CURL 종료 코드: $curl_exit_code"
    
    if [[ $curl_exit_code -ne 0 ]]; then
        echo "❌ SBOM 업로드 실패"
        return 1
    fi

echo "[DEBUG] 업로드 완료, 다음 단계 시작"
    
    # 2. 업로드 완료 후 CVSS 점검
    echo "[⏳] 잠시 대기하세요 ... (CVSS 점검중)"
    
    echo "[DEBUG] sleep 시작"
    sleep 10
    echo "[DEBUG] sleep 완료"
    
    echo "[DEBUG] check_cvss 함수 존재 확인"
    if type check_cvss &>/dev/null; then
        echo "[DEBUG] check_cvss 함수 발견됨"
    else
        echo "[ERROR] check_cvss 함수가 정의되지 않음"
        return 1
    fi
    
    echo "[DEBUG] check_cvss 호출 시작"
    check_cvss "$PROJECT_UUID" "$DT_API_KEY" "$DT_URL" "$REPO_NAME" || {
        echo "❌ [Debug] CVSS 점검 실패 - 하지만 SBOM 업로드는 완료됨"
        return 1
    }
    
    echo "[DEBUG] check_cvss 완료"
    echo "✅ SBOM 업로드 완료"
}
