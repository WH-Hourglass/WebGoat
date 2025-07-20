#!/usr/bin/env python3
import os
import sys
import requests
import json
from dotenv import load_dotenv

load_dotenv()

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

        for vuln in detailed_list[:10]:  # 최대 10개 표시
            vuln_text = f"- *{vuln['id']}* (Score: {vuln['score']}) – `{vuln['component']}`"
            blocks.append({
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": vuln_text
                }
            })

    return json.dumps({ "blocks": blocks })


def main():
    if len(sys.argv) != 6:
        print("❌ 사용법: python check_cvss_and_notify.py <PROJECT_UUID> <API_KEY> <DT_URL> <REPO_NAME> <PROJECT_VERSION>")
        sys.exit(1)
    project_version ="Unknown"
    project_uuid, api_key, dt_url, repo_name, project_version = sys.argv[1:]
    base_url = dt_url.rstrip("/")
    headers = {"X-Api-Key": api_key}

    # 1. 프로젝트 이름, 버전 조회
    project_name = repo_name
    #project_version = "Unknown"
    #project_info_url = f"{base_url}/api/v1/project/{project_uuid}"
    #project_info_res = requests.get(project_info_url, headers=headers)
    #try:
    #    if project_info_res.status_code == 200:
    #        project_info = project_info_res.json()
    #        project_name = project_info.get("name", repo_name)
    #        project_version = project_info.get("version", "Unknown")
    #except Exception:
    #    pass

    # 2. 메트릭 조회
    metrics_url = f"{base_url}/api/v1/metrics/project/{project_uuid}/current"
    res = requests.get(metrics_url, headers=headers)
    try:
        metrics = res.json()
        if isinstance(metrics, list):
            metrics = metrics[0]
    except Exception:
        print("❌ 메트릭 데이터를 파싱할 수 없습니다.")
        print(f"[DEBUG] Status Code: {res.status_code}")
        print(f"[DEBUG] Response Text: {res.text}")
        sys.exit(1)

    critical = metrics.get("critical", 0)
    high = metrics.get("high", 0)
    medium = metrics.get("medium", 0)
    low = metrics.get("low", 0)

    # 3. CVSS 9 이상 항목 추출
    detailed_url = f"{base_url}/api/v1/vulnerability/project/{project_uuid}"
    res_vuln = requests.get(detailed_url, headers=headers)
    try:
        vuln_list = res_vuln.json()
    except Exception:
        vuln_list = []

    critical_vulns = []
    for vuln in vuln_list:
        score = 0
        if "cvssV3" in vuln and vuln["cvssV3"]:
            score = vuln["cvssV3"].get("baseScore", 0)
        elif "cvssV2" in vuln and vuln["cvssV2"]:
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
                component.get("uuid")
            )
            critical_vulns.append({
                "id": vuln.get("vulnId", "UNKNOWN"),
                "score": score,
                "component": component_name
            })

    # 4. 정책 판정
    if critical_vulns:
        result_msg = f"❌ *정책 위반* - CVSS 9 이상 취약점 {len(critical_vulns)}건 발견됨."
        exit_code = 2
    else:
        result_msg = "✅ *통과* - CVSS 9 이상 취약점 없음."
        exit_code = 0

    # 5. 요약 출력
    summary = f"""
*정책 결과:* {result_msg}

*취약점 요약:*
• CVSS 9 이상: {len(critical_vulns)}
• Critical: {critical}
• High: {high}
• Medium: {medium}
• Low: {low}
"""
    print(summary)

    # 6. Slack 전송
    slack_webhook_url = os.getenv("SLACK_WEBHOOK_URL")
    if slack_webhook_url:
        payload = generate_slack_payload(summary, critical_vulns, project_name, project_version)
        slack_res = requests.post(slack_webhook_url, headers={"Content-Type": "application/json"}, data=payload)
        if slack_res.status_code != 200:
            print("⚠️ Slack 알림 전송 실패")
            print(slack_res.text)
    else:
        print("⚠️ SLACK_WEBHOOK_URL 환경변수가 설정되어 있지 않습니다.")

    sys.exit(exit_code)

if __name__ == "__main__":
    main()
