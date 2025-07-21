#!/bin/bash
source components/dot.env
# 기본값
CONTAINER_NAME="${BUILD_TAG}"
IMAGE_TAG="${DYNAMIC_IMAGE_TAG}"
ZAP_SCRIPT="${ZAP_SCRIPT:-zap_scan.sh}"
ZAP_BIN="${ZAP_BIN:-$HOME/zap/zap.sh}" # zap.sh 실행 경로
startpage="${1:-}"

# 체크아웃된 저장소에서 ZAP 스크립트 경로 설정
ZAP_SCRIPT_PATH="${WORKSPACE}/components/scripts/zap_scan.sh"

echo "🔧 ECR_REPO: $ECR_REPO"
echo "DEBUG: 변수 설정 완료"

# Docker 이미지의 EXPOSE된 포트를 감지하는 함수
detect_internal_port() {
    local image="$1"
    local detected_port=""
    
    echo "[*] Docker 이미지 EXPOSE 포트 확인 중..." >&2
    
    # 이미지 존재 확인
    if ! docker inspect "$image" > /dev/null 2>&1; then
        echo "[ERROR] 이미지를 찾을 수 없습니다: $image" >&2
        echo "80"
        return 1
    fi
    
    # EXPOSE된 포트 확인
    exposed_ports=$(docker inspect "$image" --format='{{range $port, $config := .Config.ExposedPorts}}{{$port}} {{end}}' 2>/dev/null | tr '/' ' ' | awk '{print $1}')
    
    if [ -n "$exposed_ports" ] && [ "$exposed_ports" != " " ] && [ "$exposed_ports" != "" ]; then
        echo "[+] EXPOSE된 포트 발견: $exposed_ports" >&2
        
        # 웹 포트 우선순위 적용 (80을 가장 높은 우선순위로)
        for preferred_port in 80 8080 3000 8000 9000 5000 4000; do
            if echo "$exposed_ports" | grep -q "^$preferred_port$"; then
                detected_port="$preferred_port"
                echo "[+] 감지된 내부 포트: $detected_port" >&2
                break
            fi
        done
        
        # 우선순위 포트가 없으면 첫 번째 포트 사용
        if [ -z "$detected_port" ]; then
            detected_port=$(echo "$exposed_ports" | awk '{print $1}')
            echo "[+] 첫 번째 EXPOSE 포트 사용: $detected_port" >&2
        fi
        
        echo "$detected_port"
        return 0
    else
        echo "[!] EXPOSE된 포트가 없습니다. 기본값 80 사용" >&2
    fi
    
    echo "80"
    return 1
}

for try_port in {8081..8089}; do
  echo "[DEBUG] 시도 중: $try_port"
  set +e
  lsof_stdout=$(lsof -iTCP:$try_port -sTCP:LISTEN -n -P 2>/dev/null)
  lsof_exit_code=$?
  set -e
  echo "[DEBUG] lsof 종료 코드: $lsof_exit_code"
  echo "[DEBUG] lsof 출력: $lsof_stdout"
  # "포트 사용 안 함" 상황 → 정상 처리
  if [ $lsof_exit_code -ne 0 ] && [ -z "$lsof_stdout" ]; then
    echo "[DEBUG] 포트 $try_port 는 사용 중 아님 (lsof 정상)"
  elif [ $lsof_exit_code -ne 0 ]; then
    echo "🚨 Error: lsof 명령 실패 (예외 상황)"
    exit 1
  fi
  # 이 포트가 사용 중이면 다음 포트로
  if [ -n "$lsof_stdout" ]; then
    continue
  fi
  # docker 검사
  in_use_docker=""
  docker_output=$(docker ps --format '{{.Ports}}' 2>/dev/null || true)
  if echo "$docker_output" | grep -E "[0-9\.]*:$try_port->" >/dev/null; then
    in_use_docker=1
  fi
  echo "[DEBUG] docker 결과: $in_use_docker"
  if [ -z "$in_use_docker" ]; then
    port=$try_port
    echo "[DEBUG] 사용 가능한 포트 발견: $port"
    if [[ "$port" =~ ^[0-9]+$ ]]; then
      zap_port=$((port + 10))
      echo "[DEBUG] ZAP 포트: $zap_port"
    else
      echo "🚨 Error: port 값이 숫자가 아님: '$port'"
      exit 1
    fi
    break
  fi
done

# 동적 변수 설정
containerName="${BUILD_TAG}"
zap_pidfile="zap_${zap_port}.pid"
zap_log="zap_${zap_port}.log"
zapJson="zap_test_${BUILD_TAG}.json"
timestamp=$(date +"%Y%m%d_%H%M%S")

# 체크아웃된 저장소의 ZAP 스크립트 확인 및 실행 권한 부여
echo "[*] ZAP 스크립트 경로 확인: $ZAP_SCRIPT_PATH"
if [ -f "$ZAP_SCRIPT_PATH" ]; then
    echo "[+] ZAP 스크립트 파일 확인 완료"
    chmod +x "$ZAP_SCRIPT_PATH"
else
    echo "❌ ZAP 스크립트 파일을 찾을 수 없습니다: $ZAP_SCRIPT_PATH"
    echo "현재 디렉터리 구조:"
    find "${WORKSPACE}" -name "*.sh" -type f | head -10
    exit 1
fi

# ZAP 작업 디렉터리 및 플러그인 디렉터리 생성 및 애드온 복사 (zap 데몬 병렬 실행할 때 에드온으로 인한 에러 방지용)
mkdir -p "$HOME/zap/zap_workdir_${zap_port}/plugin"
ZAP_BIN_DIR=$(dirname "$ZAP_BIN")
cp "${ZAP_BIN_DIR}/plugin/"*.zap "$HOME/zap/zap_workdir_${zap_port}/plugin/"

echo "[*] Docker 이미지 pull 중..."
docker pull "$ECR_REPO:${DYNAMIC_IMAGE_TAG}"

# 내부 포트 감지
internal_port=$(detect_internal_port "$ECR_REPO:${DYNAMIC_IMAGE_TAG}")

if [ -z "$internal_port" ] || ! [[ "$internal_port" =~ ^[0-9]+$ ]]; then
    echo "❌ 유효한 내부 포트를 감지하지 못했습니다. 기본값 80 사용"
    internal_port="80"
fi

echo "[*] 웹앱 컨테이너: $containerName (외부 포트: $port → 내부 포트: $internal_port)"
echo "[*] ZAP 데몬: zap.sh (포트 $zap_port)"

echo "[*] 웹앱 컨테이너 실행"
docker run -d --name "$containerName" -p "${port}:${internal_port}" "$ECR_REPO:${DYNAMIC_IMAGE_TAG}"
sleep 3

if ! docker ps | grep "$containerName" > /dev/null; then
    echo "❌ 컨테이너 시작 실패"
    echo "컨테이너 상태:"
    docker ps -a | grep "$containerName"
    echo "컨테이너 로그:"
    docker logs "$containerName"
    exit 1
fi

# 컨테이너 헬스체크
echo "[*] 컨테이너 헬스체크 중..."
health_check_success=false
for i in {1..30}; do
    if curl -s --connect-timeout 2 "http://localhost:$port" > /dev/null 2>&1; then
        echo "[+] 웹앱 컨테이너 헬스체크 성공 (시도 $i/30)"
        health_check_success=true
        break
    fi
    echo "[DEBUG] 헬스체크 시도 $i/30 실패, 2초 대기..."
    sleep 2
done

if [ "$health_check_success" = false ]; then
    echo "⚠️ 헬스체크 실패했지만 계속 진행합니다"
    echo "컨테이너 로그:"
    docker logs "$containerName" | tail -20
fi

echo "[*] ZAP 데몬 실행 중..."
# 데몬을 -dir 명령어로 실행해서 병렬 실행 가능하도록 하는 것임 zap_workdir_${zap_port}는 zap 데몬용 디렉터리
nohup "$ZAP_BIN" -daemon -port "$zap_port" -host 127.0.0.1 -config api.disablekey=true -dir "zap_workdir_${zap_port}" >"$zap_log" 2>&1 &
echo $! >"$zap_pidfile"

for i in {1..60}; do # 데몬 실행 체크도 그냥 여기서 하도록 코드 옮김
  curl -s "http://127.0.0.1:$zap_port" > /dev/null && { echo "[+] ZAP 준비 완료"; break; }
  sleep 1
done 

echo "[*] 체크아웃된 저장소의 ZAP 스크립트 실행"
"$ZAP_SCRIPT_PATH" "$containerName" "$zap_port" "$startpage" "$port" # $port인자 추가

# ZAP 스크립트가 실제로 생성하는 파일명
ZAP_RESULT_FILE="$HOME/zap_${containerName}.json"

# 파일 존재 확인
if [ ! -f "$ZAP_RESULT_FILE" ]; then
    echo "❌ ZAP 결과 파일이 존재하지 않습니다: $ZAP_RESULT_FILE"
    echo "현재 홈 디렉터리의 ZAP 관련 파일들:"
    ls -la ~/zap_* 2>/dev/null || echo "ZAP 파일 없음"
    exit 1
fi

echo "[+] ZAP 결과 파일 확인: $ZAP_RESULT_FILE"

echo "[*] S3 업로드"
if aws s3 cp "$ZAP_RESULT_FILE" "s3://${S3_BUCKET_DAST}/${s3_key}" --region "$REGION"; then
    echo "✅ S3 업로드 완료 → s3://${S3_BUCKET_DAST}/${s3_key}"
else
    echo "⚠️ S3 업로드 실패 (무시)"
fi

# 리포트 디렉터리 설정 및 생성
REPORT_DIR="$HOME/report/${JOB_NAME}"
echo "[*] 리포트 디렉터리 설정: $REPORT_DIR"

# 디렉터리가 없으면 생성
if [ ! -d "$REPORT_DIR" ]; then
    echo "[*] 리포트 디렉터리 생성 중..."
    mkdir -p "$REPORT_DIR"
    if [ $? -eq 0 ]; then
        echo "✅ 리포트 디렉터리 생성 완료: $REPORT_DIR"
    else
        echo "❌ 리포트 디렉터리 생성 실패: $REPORT_DIR"
        exit 1
    fi
else
    echo "[+] 리포트 디렉터리 이미 존재: $REPORT_DIR"
fi

echo "[*] 리포트 파일을 $REPORT_DIR 로 이동"
if [ -f "$ZAP_RESULT_FILE" ]; then
    final_filename="zap_${containerName}.json"
    mv "$ZAP_RESULT_FILE" "$REPORT_DIR/$final_filename"
    if [ $? -eq 0 ]; then
        echo "✅ 파일 이동 완료: $REPORT_DIR/$final_filename"
        echo "[+] 저장된 리포트: $REPORT_DIR/$final_filename"
    else
        echo "❌ 파일 이동 실패"
        exit 1
    fi
else
    echo "⚠️ 이동할 파일이 없습니다: $ZAP_RESULT_FILE"
fi

echo "[*] 정리 중..."
docker rm -f "$containerName" 2>/dev/null && echo "🧹 웹앱 컨테이너 제거 완료" || echo "⚠️ 웹앱 컨테이너 제거 실패"

if [ -f "$zap_pidfile" ]; then
  kill "$(cat "$zap_pidfile")" && echo "🧹 ZAP 데몬 종료 완료" || echo "⚠️ ZAP 데몬 종료 실패"
  rm -f "$zap_pidfile"
  sleep 2
fi

if [ -d "$HOME/zap/zap_workdir_${zap_port}" ]; then
  rm -rf "$HOME/zap/zap_workdir_${zap_port}" && echo "🧹 ZAP 작업 디렉터리 제거 완료" || echo "⚠️ ZAP 작업 디렉터리 제거 실패"
fi
