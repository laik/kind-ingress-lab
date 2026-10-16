#!/bin/sh
# 在 nginx 容器内运行的主动健康检查 + 自动摘流（控油）
#
# HC_MODE=l7 (默认)  探测 http://<infra-node>:31000/healthz，判 HTTP 200
# HC_MODE=l4         只做 <infra-node>:31000 的 TCP connect（nc -z -w），不看应用层
#
# L4 探测只证明“这个 IP 的 NodePort 有人 accept”；
# 它看不到 TCP 建起来之后 HTTP 层能不能真的出响应（见 README 坑#16）。
#
# L7 探测目标:
#   - 不带业务 Host 头，命中 ingress-nginx 默认 server 的 `location /healthz { return 200; }`
#   - 判 HTTP 状态码 == 200，不判 body（body 是空的）
# 为什么这个信号是可信的:
#   ingress-nginx 的 readinessProbe 打的是 :10254/healthz，pod 不健康会被摘出 EndpointSlice；
#   某节点本地 endpoint 全空时 kube-proxy 对该节点的 NodePort 直接 DROP，
#   所以 /healthz 探测同时覆盖了「节点可达 + 有本地 endpoint + nginx 默认 server 活着」。
#
# 防抖: 连续 FAIL_MAX 次失败才摘除，连续 OK_MAX 次成功才加回。
set -u

NODES=/etc/nginx/upstream/nodes
OUT=/etc/nginx/upstream/nodeports.conf
TMP=/etc/nginx/upstream/.nodeports.new
# 人工下线名单（维护窗口用，由 scripts/lb-mark.sh 维护）。
# 必须在这里合并：否则健康检查下一轮会把维护脚本写的 down 覆盖掉（两个写入者互相覆盖）。
MDOWN=/etc/nginx/upstream/manual_down.list
# 人工“保持在线”名单：计划内维护时，节点侧已经自己摘流了（新连接会被 RST），
# 这时健康检查再去 REMOVE/ADD 只会白白多两次 reload（实测每次打断 3~8/5000 个客户端连接）。
# 把正在维护的节点写进这个名单 ⇒ 健康检查不探测、不摘、不加入（保持现状）。
MHOLD=/etc/nginx/upstream/manual_hold.list
# 人工下线导致“一个可用节点都不剩”时的保险：默认拒绝执行（保持上一版配置）。
# 真要清空入口是显式动作，需要先 touch 这个文件。
FORCE_ALL=/etc/nginx/upstream/force_all_down
STATEDIR=/tmp/hc

MODE=${HC_MODE:-l7}
PORT=${HC_PORT:-31000}
HPATH=${HC_PATH:-/healthz}
INTERVAL=${HC_INTERVAL:-5}
FAIL_MAX=${HC_FAIL:-3}
OK_MAX=${HC_OK:-2}
TIMEOUT=${HC_TIMEOUT:-2}

mkdir -p "$STATEDIR" "$(dirname "$OUT")"

log() { echo "[hc $(date -u '+%H:%M:%S')] $*"; }

probe_l7() { # ip -> 0 if HTTP 200
  code=$(wget -S -O- -q -T "$TIMEOUT" "http://$1:$PORT$HPATH" 2>&1 >/dev/null \
         | awk '/HTTP\//{print $2; exit}')
  [ "$code" = "200" ]
}

probe_l4() { # ip -> 0 if TCP connect 成功（不看任何应用层内容）
  nc -z -w "$TIMEOUT" "$1" "$PORT" >/dev/null 2>&1
}

probe() {
  case "$MODE" in
    l4) probe_l4 "$1" ;;
    *)  probe_l7 "$1" ;;
  esac
}

state_of() { cat "$STATEDIR/$1.state" 2>/dev/null || echo in; }   # 初始乐观: 全部视为可用
set_state() { echo "$2" > "$STATEDIR/$1.state"; }
in_hold() { [ -f "$MHOLD" ] && grep -qx "$1" "$MHOLD" 2>/dev/null; }
cnt() { v=$(cat "$STATEDIR/$1.$2" 2>/dev/null); case "$v" in ''|*[!0-9]*) v=0;; esac; echo "$v"; }
setcnt() { echo "$3" > "$STATEDIR/$1.$2"; }   # setcnt <ip> <fails|oks> <值>

PIDFILE=/var/run/nginx.pid
dirty=0

while :; do
  # nginx 还没起来时不要尝试 reload（entrypoint 里 hc 比 nginx 先启动）
  if [ ! -f "$PIDFILE" ]; then sleep 1; continue; fi
  [ -f "$NODES" ] || { sleep "$INTERVAL"; continue; }
  # 候选列表为空（文件刚被截断 / 标签被误删）时不要重写 upstream，
  # 否则会把一个好好的池子清空 → “no live upstreams” → 全量 502。
  LIST=$(tr -d '\r' < "$NODES")
  if [ -z "$LIST" ]; then log "候选列表为空，跳过本轮"; sleep "$INTERVAL"; continue; fi

  for ip in $LIST; do
    # 维护中的节点：不探测、不摘除。节点侧已经把自己摘干净了（新连接 RST），
    # 再 REMOVE 一次只会多一次 reload。
    if in_hold "$ip"; then continue; fi
    if probe "$ip"; then
      setcnt "$ip" fails 0
      setcnt "$ip" oks $(( $(cnt "$ip" oks) + 1 ))
      if [ "$(state_of "$ip")" = out ] && [ "$(cnt "$ip" oks)" -ge "$OK_MAX" ]; then
        set_state "$ip" in; log "ADD    $ip:$PORT  (连续 $(cnt "$ip" oks) 次 ${MODE} 探测成功)"
      fi
    else
      setcnt "$ip" oks 0
      setcnt "$ip" fails $(( $(cnt "$ip" fails) + 1 ))
      if [ "$(state_of "$ip")" = in ] && [ "$(cnt "$ip" fails)" -ge "$FAIL_MAX" ]; then
        set_state "$ip" out; log "REMOVE $ip:$PORT  (连续 $(cnt "$ip" fails) 次 ${MODE} 探测失败)"
      fi
    fi
  done

  {
    echo "# 由容器内 ${MODE} 健康检查自动生成，勿手改 (mode=${MODE} path=$HPATH interval=${INTERVAL}s fail=${FAIL_MAX} ok=${OK_MAX})"
    n=0
    for ip in $LIST; do
      # 维护中的节点强制保持可用（不因探测失败而被剔除）
      if ! in_hold "$ip"; then [ "$(state_of "$ip")" = in ] || continue; fi
      # 人工下线的节点：保留成员行但标 down（语义明确、nginx -T 里能看出是谁摘的），
      # 且不计入“可用节点数”——这样自动摘流不会把它悄悄加回来。
      if [ -f "$MDOWN" ] && grep -q "^$ip\([[:space:]]\|$\)" "$MDOWN"; then
        echo "        server $ip:$PORT max_fails=3 fail_timeout=15s down;   # 人工下线（维护）"
        continue
      fi
      echo "        server $ip:$PORT max_fails=3 fail_timeout=15s;"
      n=$((n + 1))
    done
    # 一个都不健康时也要让 upstream 语法合法：显式置 down，客户端拿到 502 而不是配置错误
    [ "$n" -eq 0 ] && echo "        server 127.0.0.1:1 down;"
  } > "$TMP"

  # 保险：如果“没有可用节点”是人工下线造成的，默认不执行（否则一个误操作就把入口打成 502）。
  # 实测踩过：维护脚本先写了 manual_down.list，健康检查下一轮老老实实把两个节点都标了 down。
  if [ "$(grep -c 'max_fails=' "$TMP")" -eq 0 ]; then
    hit=0
    if [ -s "$MDOWN" ]; then
      while read -r m; do
        m=$(echo "$m" | tr -d ' \r')
        [ -n "$m" ] || continue
        case " $LIST " in *" $m "*) hit=1 ;; esac
      done < "$MDOWN"
    fi
    if [ "$hit" = 1 ] && [ ! -f "$FORCE_ALL" ]; then
      log "拒绍应用：可用节点为 0 且命中人工下线名单（$MDOWN）；确认要清空入口请 touch $FORCE_ALL"
      rm -f "$TMP"; sleep "$INTERVAL"; continue
    fi
  fi

  if ! cmp -s "$TMP" "$OUT" 2>/dev/null; then
    mv "$TMP" "$OUT"
    log "upstream 变更 -> $(grep -c 'max_fails=' "$OUT") 个可用节点，reload nginx"
    dirty=1
  else
    rm -f "$TMP"
  fi

  if [ "$dirty" = 1 ]; then
    if nginx -s reload 2>&1; then dirty=0; else log "reload 失败，下轮重试"; fi
  fi

  sleep "$INTERVAL"
done
