#!/bin/sh
# 容器入口: 后台跑主动健康检查循环（负责摘流/加回），前台跑 nginx
HC=${HC_ENABLED:-1}
if [ "$HC" = "1" ]; then
  sh /etc/nginx/scripts/healthcheck.sh &
  echo "[entrypoint] ${HC_MODE:-l7} healthcheck started (mode=${HC_MODE:-l7} path=${HC_PATH:-/healthz} interval=${HC_INTERVAL:-2}s fail=${HC_FAIL:-2} ok=${HC_OK:-2} timeout=${HC_TIMEOUT:-2}s)"
fi
exec nginx -g 'daemon off;'
