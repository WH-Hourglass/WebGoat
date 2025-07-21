#!/bin/bash

set -e

REPO_URL="$1"
REPO_NAME="$2"
BUILD_ID="$3"

if [[ -z "$REPO_URL" || -z "$REPO_NAME" ]]; then
    echo "❌ REPO_URL과 REPO_NAME을 인자로 전달해야 합니다."
    exit 1
fi

if [[ -z "$BUILD_ID" ]]; then
    BUILD_ID="$(date +%s%N)"
fi

REPO_DIR="/tmp/${REPO_NAME}_${BUILD_ID}"
echo "[+] 클린 작업: ${REPO_DIR} 제거"
rm -rf "${REPO_DIR}"

echo "[+] Git 저장소 클론: ${REPO_URL}"
git clone "${REPO_URL}" "${REPO_DIR}"

echo "[+] 언어 및 Java 버전 탐지 시작"
cd "$REPO_DIR" || exit 1

IMAGE_TAG="cli"  # 기본값
JAVA_VERSION=""
BUILD_FILE=""

# Maven, Gradle 기반 빌드 파일 자동 감지
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

# 자바 기반 프로젝트인 경우
if [[ -n "$BUILD_FILE" ]]; then
    #SCRIPT_DIR="/home/ec2-user"
    JAVA_VERSION=$(python3 "$WORKSPACE/components/scripts/pom_to_docker_image.py" "$BUILD_FILE" 2>/dev/null | tr -d '\r')

  if [[ -z "$JAVA_VERSION" ]]; then
    echo "[⚠️] Bedrock 기반 감지 실패 – 기본 java 사용"
    IMAGE_TAG="java"
  else
    echo "[✅] 감지된 Java 버전: $JAVA_VERSION"
    #SCRIPT_DIR="/home/ec2-user"
    IMAGE_TAG=$(python3 "$WORKSPACE/components/scripts/docker_tag.py" "$JAVA_VERSION" 2>/dev/null | tr -d '\r')
    [[ -z "$IMAGE_TAG" ]] && IMAGE_TAG="java"
  fi

# Java 외 언어 프로젝트
elif [[ -f "package.json" || -f "requirements.txt" || -f "pyproject.toml" || -f "go.mod" || -f "Cargo.toml" ]]; then
  echo "[ℹ️] Java 외 언어 프로젝트 감지됨 – CLI 이미지 사용"
  IMAGE_TAG="cli"
  JAVA_VERSION="Not_Java"

# 빌드 파일 없음
else
  echo "[⚠️] 지원되는 빌드 파일을 감지하지 못함 – 기본(cli) 사용"
  IMAGE_TAG="cli"
  JAVA_VERSION="UNKNOWN"
fi

# 결과 저장
echo "[ℹ️] 최종 선택된 Docker 이미지 태그: $IMAGE_TAG"
echo "$IMAGE_TAG" > "/tmp/cdxgen_image_tag_${REPO_NAME}_${BUILD_ID}.txt"
echo "$JAVA_VERSION" > "/tmp/cdxgen_java_version_${REPO_NAME}_${BUILD_ID}.txt"


IMAGE_TAG=$(cat /tmp/cdxgen_image_tag_${REPO_NAME}_${BUILD_ID}.txt)
echo "[+] 선택된 CDXGEN 이미지 태그: $IMAGE_TAG"

echo "[+] REPO_NAME: $REPO_NAME"
echo "[+] BUILD_ID: $BUILD_ID"

if [[ "$IMAGE_TAG" == "cli" ]]; then
    echo "[🚀] CDXGEN(CLI) 도커 실행"
    docker run --rm -v "$REPO_DIR:/app" ghcr.io/cyclonedx/cdxgen:latest -o "sbom_${REPO_NAME}_${BUILD_ID}.json"
else
    echo "[🚀] CDXGEN(Java) 도커 실행 ($IMAGE_TAG)"
    docker run --rm -v "$REPO_DIR:/app" ghcr.io/cyclonedx/cdxgen-"$IMAGE_TAG":latest -o "sbom_${REPO_NAME}_${BUILD_ID}.json"
fi

echo "[+] Dependency-Track 컨테이너 상태 확인"
if docker ps --format '{{.Names}}' | grep -q '^dependency-track$'; then
    echo "[+] Dependency-Track 컨테이너 실행 중"
elif docker ps -a --format '{{.Names}}' | grep -q '^dependency-track$'; then
    echo "[+] Dependency-Track 멈춤 상태 → 기동"
    docker start dependency-track
else
    echo "[+] Dependency-Track 컨테이너 없음 → 새 기동"
    docker run -d --name dependency-track -p 8080:8080 dependencytrack/bundled:latest
fi

echo "[+] Dependency-Track 업로드"
source /home/ec2-user/.env

REPO_DIR="/tmp/${REPO_NAME}_${BUILD_ID}"

if [[ -z "$REPO_NAME" || -z "$BUILD_ID" ]]; then
    echo "❌ 사용법: $0 <REPO_NAME> <BUILD_ID>"
    exit 1
fi

SBOM_FILE="${REPO_DIR}/sbom_${REPO_NAME}_${BUILD_ID}.json"

if [[ ! -f "$SBOM_FILE" ]]; then
    echo "❌ SBOM 파일이 존재하지 않습니다: $SBOM_FILE"
    exit 1
fi

PROJECT_VERSION="${BUILD_ID}_$(date +%Y%m%d_%H%M%S)"

echo "🚀 SBOM 업로드 시작: $SBOM_FILE (projectVersion: $PROJECT_VERSION)"

curl -X POST http://localhost:8080/api/v1/bom \
  -H "X-Api-Key: $DT_API_KEY" \
  -F "projectName=$REPO_NAME" \
  -F "projectVersion=$PROJECT_VERSION" \
  -F "bom=@$SBOM_FILE" \
  -F "autoCreate=true"

if [[ $? -ne 0 ]]; then
    echo "❌ SBOM 업로드 실패"
    exit 1
fi

# 프로젝트 UUID 조회
PROJECT_UUID=$(curl -s -X GET "http://localhost:8080/api/v1/project?name=${REPO_NAME}&version=${PROJECT_VERSION}" \
  -H "X-Api-Key: $DT_API_KEY" | jq -r '.[0].uuid')

if [[ -z "$PROJECT_UUID" || "$PROJECT_UUID" == "null" ]]; then
    echo "❌ 프로젝트 UUID를 찾을 수 없습니다."
    exit 1
fi

# 분석 완료까지 대기 (최대 60초), 메시지 없이
MAX_WAIT=90
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    METRICS_JSON=$(curl -s -X GET "http://localhost:8080/api/v1/project/${PROJECT_UUID}" -H "X-Api-Key: $DT_API_KEY")
    VULN_COUNT=$(echo "$METRICS_JSON" | jq '.metrics.vulnerabilities' 2>/dev/null)

    if [[ "$VULN_COUNT" =~ ^[0-9]+$ ]]; then
        break
    fi

    sleep 5
    WAITED=$((WAITED + 5))
done

# CVSS 9 이상 정책 검사
echo "📤 CVSS 9 이상 정책 검사 중..."
python3 "$WORKSPACE/components/scripts/check_cvss_and_notify.py" "$PROJECT_UUID" "$DT_API_KEY" "http://localhost:8080" "$REPO_NAME" "$PROJECT_VERSION" "$DYNAMIC_IMAGE_TAG" 2>&1


