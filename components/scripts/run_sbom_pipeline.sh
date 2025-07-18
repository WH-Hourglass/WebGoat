//앞으로 변경 없을 예정 
//dt 에 업로드할때 충돌 안나게 인자값 조정한 ver

#!/bin/bash
set -e

REPO_URL="$1"
REPO_NAME="$2"  # 이제 병렬 실행 시 고유한 이름이 전달됨
VERSION="$3"
COMMIT_ID="$4"  # 병렬 실행 시 커밋 ID 전달됨

# REPO_NAME과 BUILD_ID는 동적으로 받는 값으로 설정
if [[ -z "$REPO_URL" || -z "$REPO_NAME" ]]; then
    echo "❌ REPO_URL과 REPO_NAME을 인자로 전달해야 합니다."
    exit 1
fi

if [[ -z "$BUILD_ID" ]]; then
    BUILD_ID="$(date +%s%N)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/functions.sh"

# 고유한 디렉터리 이름 생성 (REPO_NAME에 이미 고유 식별자 포함)
REPO_DIR="/tmp/${REPO_NAME}_${BUILD_ID}"
LOG_FILE="/tmp/sbom_runlog_${REPO_NAME}_${BUILD_ID}.log"

# 공유 컨테이너 이름 (모든 병렬 작업이 동일한 DT 인스턴스 사용)
CONTAINER_NAME="dependency-track"

mkdir -p "$REPO_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "📌 로그 기록 시작: $LOG_FILE"
echo "[+] 병렬 작업 식별자: $REPO_NAME"

echo "[+] 클린 작업: ${REPO_DIR} 제거"
rm -rf "$REPO_DIR"

echo "[+] Git 저장소 클론: ${REPO_URL} → ${REPO_DIR}"
git clone "$REPO_URL" "$REPO_DIR"

cd "$REPO_DIR"

if [[ -n "$COMMIT_ID" ]]; then
    echo "[+] 커밋 체크아웃: $COMMIT_ID"
    git checkout "$COMMIT_ID"
fi

detect_java_version "$REPO_NAME" "$VERSION"

IMAGE_TAG=$(cat "/tmp/cdxgen_image_tag_${REPO_NAME}_${VERSION}.txt")
echo "[+] 선택된 CDXGEN 이미지 태그: $IMAGE_TAG"

SBOM_FILE="${REPO_DIR}/sbom_${REPO_NAME}_${BUILD_ID}.json"

if [[ "$IMAGE_TAG" == "cli" ]]; then
    echo "[🚀] CDXGEN(CLI) 도커 실행"
    docker run --rm -v "${REPO_DIR}:/app" ghcr.io/cyclonedx/cdxgen:latest -o "$SBOM_FILE"
else
    echo "[🚀] CDXGEN(Java) 도커 실행 ($IMAGE_TAG)"
    docker run --rm -v "${REPO_DIR}:/app" ghcr.io/cyclonedx/cdxgen-${IMAGE_TAG}:latest -o "$SBOM_FILE"
fi

echo "[+] Dependency-Track 컨테이너 상태 확인 (공유 컨테이너: $CONTAINER_NAME)"

# 공유 컨테이너 관리 (동시 접근 안전성을 위한 락 메커니즘)
LOCK_FILE="/tmp/dependency-track.lock"

# 락 획득 (최대 30초 대기)
echo "[+] 컨테이너 락 획득 시도..."
(
    flock -x -w 30 200 || exit 1
    
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[+] Dependency-Track 컨테이너 이미 실행 중: $CONTAINER_NAME"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[+] Dependency-Track 멈춤 상태 → 기동: $CONTAINER_NAME"
        docker start "$CONTAINER_NAME"
    else
        echo "[+] Dependency-Track 컨테이너 없음 → 새 기동: $CONTAINER_NAME"
        docker run -d --name "$CONTAINER_NAME" -p 8080:8080 dependencytrack/bundled:latest
    fi
    
    # 컨테이너 시작 대기 (첫 번째 실행 시에만)
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[+] Dependency-Track 컨테이너 시작 대기..."
        sleep 15
    fi
    
) 200>"$LOCK_FILE"

echo "[+] 컨테이너 준비 완료"

# upload_sbom 함수 호출 시 락 사용 (동시 업로드 방지)
echo "[+] SBOM 업로드 시작 (락 사용)"
(
    flock -x -w 60 201 || exit 1
    upload_sbom "$REPO_NAME" "$VERSION" "$REPO_DIR" "$COMMIT_ID"
    echo "[+] SBOM 업로드 완료: $REPO_NAME"
) 201>"${LOCK_FILE}.upload"

echo "[✅] SBOM 파이프라인 완료: $REPO_NAME"

echo "[DEBUG] check_cvss 함수 호출 시작"
(
    python3 /home/ec2-user/check_cvss_and_notify_2.py "$REPO_NAME" "$VERSION" "$DT_API_KEY" "http://localhost:8080"
) || {
    echo "❌ CVSS 점검 실패"
}


# 정리: 임시 파일 삭제
rm -f "/tmp/cdxgen_image_tag_${REPO_NAME}_${BUILD_ID}.txt"

# 컨테이너는 공유하므로 정리하지 않음
# echo "[+] 정리: 컨테이너 $CONTAINER_NAME 중지"
# docker stop "$CONTAINER_NAME" || true
# docker rm "$CONTAINER_NAME" || true
