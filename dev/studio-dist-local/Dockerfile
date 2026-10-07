# lucy-studio-dist 참조 구현 (온프렘 로컬 검증용).
# 정식 Dockerfile 은 project_lucy/studio/dist-image/ 에 두며, 이 파일은 그 계약(Notion 3.1/3.4)을
# 그대로 구현해 온프렘 패키지 쪽에서 미리 검증하기 위한 것이다.
FROM nginx:1.26-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /usr/local/bin/studio-dist-entrypoint.sh

# dist/      : 웹 루트에 그대로 서빙되는 파일 (설치 파일, 업데이트 본문, 델타, latest.json)
# templates/ : 피드 템플릿(*.tmpl). 웹 루트 밖에 두고 기동 시 렌더링한다.
COPY dist/ /usr/share/nginx/html/
COPY templates/ /opt/studio-dist/templates/

RUN chmod +x /usr/local/bin/studio-dist-entrypoint.sh \
 && rm -f /usr/share/nginx/html/index.html /usr/share/nginx/html/50x.html

ENTRYPOINT ["/usr/local/bin/studio-dist-entrypoint.sh"]
