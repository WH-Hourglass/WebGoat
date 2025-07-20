#!/usr/bin/env python3
import os
import sys
import requests
import json
from dotenv import load_dotenv

load_dotenv()

# 로그 기록 함수
def log_message(message):
    log_file_path = "/home/ec2-user/check_cvss_and_notify.log"
    try:
        with open(log_file_path, "a") as log_file:
            log_file.write(f"{message}\n")
    except Exception as e:
        print(f"[❌] 로그 기록 중 오류 발생: {e}")

# Slack 페이로드 생성
def generate_slack_payload(summary_text, detailed_list, repo_name, project_version):
    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"🚨 Dependency-Track 보안 보고서: {repo_name} ({project_version})"
            }
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": summary_text
            }
        }
    ]

    if detailed_list:
        blocks.append({"type": "divider"})
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": "*CVSS 9 이상 취약점 목록:*"
            }
        })

        for vuln in detailed_list[:10]:
            vuln_text = f"- *{vuln['id']}* (Score: {vuln['score']}) – `{vuln['component']}`"
            blocks.append({
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": vuln_text
                }
            })

    return json.dumps({"blocks": blocks})

# UUID 조회
def get_project_uuid(repo_name, project_version, api_key, dt_url):
    log_message(f"[+] 프로젝트 UUID 조회 중: {repo_name} ({project_version})")
    try:
        response = requests.get(f"{dt_url}/api/v1/project", headers={"X-Api-Key": api_key})
        response.raise_for_status()
        projects = response.json()
        for project in projects:
            if project["name"] == repo_name and project["version"] == project_version:
                log_message(f"[✅] 프로젝트 UUID: {project['uuid']}")
                return project["uuid"]
    except Exception as e:
        log_message(f"[❌] UUID 조회 실패: {e}")
    return None

# 메인 로직
def main():
    if len(sys.argv) != 5:
        log_message("❌ 사용법: python check_cvss_and_notify.py <REPO_NAME> <PROJECT_VERSION> <API_KEY> <DT_URL>")
        sys.exit(1)

    repo_name, project_version, api_key, dt_url = sys.argv[1:]
    dt_url = dt_url.rstrip("/")
    headers = {"X-Api-Key": api_key}

    # UUID 조회
    uuid = get_project_uuid(repo_name, project_version, api_key, dt_url)
    if not uuid:
        log_message("❌ 프로젝트 UUID 조회 실패")
        sys.exit(1)

    # 메트릭 조회
    metrics_url = f"{dt_url}/api/v1/metrics/project/{uuid}/current"
    try:
        metrics_res = requests.get(metrics_url, headers=headers)
        metrics_res.raise_for_status()
        metrics = metrics_res.json()
        if isinstance(metrics, list):
            metrics = metrics[0]
    except Exception as e:
        log_message(f"[❌] 메트릭 조회 실패: {e}")
        sys.exit(1)

    critical = metrics.get("critical", 0)
    high = metrics.get("high", 0)
    medium = metrics.get("medium", 0)
    low = metrics.get("low", 0)

    # 취약점 상세 조회
    detailed_url = f"{dt_url}/api/v1/vulnerability/project/{uuid}"
    try:
        detailed_res = requests.get(detailed_url, headers=headers)
        detailed_res.raise_for_status()
        vuln_list = detailed_res.json()
    except Exception as e:
        log_message(f"[❌] 취약점 조회 실패: {e}")
        vuln_list = []

    # CVSS 9 이상 필터링
    critical_vulns = []
    for vuln in vuln_list:
        score = 0
        if vuln.get("cvssV3"):
            score = vuln["cvssV3"].get("baseScore", 0)
        elif vuln.get("cvssV2"):
            score = vuln["cvssV2"].get("baseScore", 0)
        elif vuln.get("severity", "").upper() == "CRITICAL":
            score = 9.0
        if score >= 9:
            component = vuln.get("component", {})
            component_name = (
                component.get("purl") or
                component.get("name") or
                component.get("group") or
                component.get("version") or
                component.get("uuid") or
                "UNKNOWN"
            )
            critical_vulns.append({
                "id": vuln.get("vulnId", "UNKNOWN"),
                "score": score,
                "component": component_name
            })

    # 정책 판정
    if critical_vulns:
        result_msg = f"❌ *정책 위반* - CVSS 9 이상 취약점 {len(critical_vulns)}건 발견됨."
        exit_code = 2
    else:
        result_msg = "✅ *통과* - CVSS 9 이상 취약점 없음."
        exit_code = 0

    summary = f"""
*정책 결과:* {result_msg}

*취약점 요약:*
• CVSS 9 이상: {len(critical_vulns)}
• Critical: {critical}
• High: {high}
• Medium: {medium}
• Low: {low}
"""
    log_message(summary.strip())

    # Slack 전송
    slack_webhook_url = os.getenv("SLACK_WEBHOOK_URL")
    if slack_webhook_url:
        try:
            log_message("[🔔] Slack 알림 전송 시작")
            payload = generate_slack_payload(summary, critical_vulns, repo_name, project_version)
            res = requests.post(slack_webhook_url, headers={"Content-Type": "application/json"}, data=payload)
            if res.status_code == 200:
                log_message("✅ Slack 알림 전송 성공")
            else:
                log_message(f"⚠️ Slack 전송 실패: {res.status_code} - {res.text}")
        except Exception as e:
            log_message(f"[❌] Slack 전송 중 오류: {e}")
    else:
        log_message("⚠️ SLACK_WEBHOOK_URL 환경변수가 설정되어 있지 않음")

    sys.exit(exit_code)

if __name__ == "__main__":
    main()
