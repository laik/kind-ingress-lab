#!/usr/bin/env bash
# 维护窗口：把某个 upstream 节点标记为 down（或恢复），并安全地 reload nginx LB。
#
#   lb-mark.sh <node-ip> down|up|status|rollback [备份文件]
#
# 事实前提（实测）：
#   * `down` 是 upstream 里的**静态参数**，开源 nginx 没有运行时 API
#     （Plus 才有 /api/http/upstreams/.../servers/.../down）。所以"标记 down"必然 = 改文件 + reload。
#   * reload 之后 nginx **立刻不再把新请求派给 down 的 server**（实测：LB 到该节点的上游连接
#     配合 keepalive_time 10s 在 12s 内归零），但已建立的连接不会立刻断，要等它空闲。
#   * 每次 reload 会打断极少量**客户端** keepalive 连接（实测 3~8 / 5000 请求）。
#
# 安全约束（脚本改坏 LB 配置 = 入口全挂，这是本脚本最大的风险；下面每条都是实测踩出来的）：
#   1. 保护检查必须在**写 manual_down.list 之前**做。顺序反了的话，"记录意图"这一步
#      就会被容器内的健康检查立刻执行 —— 实测把最后一个可用节点也标 down，入口直接 502。
#   2. 拒绝把可用节点数降到 MIN_ACTIVE 以下（默认 1），除非 FORCE=1。
#   3. 原子替换（同目录 tmp + mv），每次改动前备份到 history/，支持 rollback。
#   4. `nginx -t` 通过才 reload；语法错 / reload 失败 / reload 后探活失败 → 自动回滚。
#   5. 区分"LB 不可达"和"配置语法错"：前者不能回滚掉一份本来正常的配置。
#   6. 变量名紧跟中文时必须用 ${}，否则 bash 会把中文字节并进变量名（set -u 下直接炸）。
#
# 生产接入：把 nginx_t / nginx_reload / verify 三个函数换成 ssh 到 LB 机器的命令即可。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UP_DIR=${UP_DIR:-$ROOT/nginx/upstream}
CONF=$UP_DIR/nodeports.conf
MDOWN=$UP_DIR/manual_down.list
HIST=$UP_DIR/history
LOCK=$UP_DIR/.lb-mark.lock
CONTAINER=${CONTAINER:-nginx-external}
MIN_ACTIVE=${MIN_ACTIVE:-1}
FORCE=${FORCE:-0}
VERIFY_URL=${VERIFY_URL:-http://127.0.0.1:8080/}
VERIFY_HOST=${VERIFY_HOST:-demo.local}

IP=${1:?用法: lb-mark.sh <node-ip> down|up|status|rollback [备份文件]}
ACT=${2:-status}
BK_ARG=${3:-}
mkdir -p "$HIST"
touch "$MDOWN"

say() { printf '%s\n' "$*"; }
die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---- 三个可替换的钩子 -----------------------------------------------------------
nginx_t() {   # 返回 0=语法ok  1=语法错  2=连不上LB
  local out rc i
  for i in 1 2 3; do
    out=$(docker exec "$CONTAINER" nginx -t 2>&1); rc=$?
    [ $rc -eq 0 ] && return 0
    case "$out" in
      "") sleep 1; continue ;;                                  # docker exec 没输出：容器没就绪
      *emerg*|*invalid*|*unexpected*|*unknown*) echo "$out" | tail -2 >&2; return 1 ;;
      *) echo "$out" | tail -2 >&2; return 1 ;;
    esac
  done
  return 2
}
nginx_reload() { docker exec "$CONTAINER" nginx -s reload >/dev/null 2>&1; }
verify() {
  local code
  code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' -H "Host: ${VERIFY_HOST}" "$VERIFY_URL" 2>/dev/null || echo 000)
  [ "$code" = "200" ] || { say "  探活失败: code=${code}"; return 1; }
}
# -------------------------------------------------------------------------------

active_count() { grep 'server ' "$CONF" 2>/dev/null | grep -vc ' down;'; }
show() { grep 'server ' "$CONF" 2>/dev/null | sed 's/^/  /'; }

backup() {
  local f="$HIST/nodeports.$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$CONF" "$f" || return 1
  ls -1t "$HIST"/nodeports.* 2>/dev/null | tail -n +21 | xargs -r rm -f 2>/dev/null
  echo "$f"
}

restore_and_reload() {   # 回滚到指定备份
  local f=${1:-}
  if [ -z "$f" ] || [ ! -s "$f" ]; then say "  !! 备份不可用，需要人工介入"; return 1; fi
  say "  回滚 -> ${f}"
  cp "$f" "$UP_DIR/.rb.tmp" && mv "$UP_DIR/.rb.tmp" "$CONF"
  nginx_reload
  sleep 1
  if verify; then say "  回滚后入口正常"; else say "  !! 回滚后探活仍失败，需要人工介入"; fi
}

# 计算新内容：mark_down / mark_up 共用
render() {   # render down|up
  local mode=$1
  awk -v ip="$IP" -v mode="$mode" '
    $0 ~ ("server " ip ":") {
      if (mode == "down") { if ($0 !~ / down;/) sub(/;[ \t]*([#].*)?$/, " down;") }
      else                { sub(/[ \t]*down;/, ";") }
    }
    { print }' "$CONF"
}

active_in() { :; }   # （保留占位，实际计数在 main 里直接算）

# 单一写入者模式：如果容器里有自动健康检查在跑，就**只写名单**，让健康检查去落盘 + reload。
# 实测：两边都写会多一次 reload（脚本写完，健康检查下一轮按自己的注释重写 → cmp 不同 → 再 reload），
# 每次 reload 都会打断客户端 keepalive 连接。只写名单 ⇒ 一次数。
hc_running() { docker exec "$CONTAINER" sh -c 'ps aux 2>/dev/null | grep -q "[h]ealthcheck"' 2>/dev/null; }
wait_hc() {   # wait_hc down|up —— 等健康检查把名单反映到 nodeports.conf
  local mode=$1 i
  for i in $(seq 1 15); do
    if [ "$mode" = down ]; then
      grep "server ${IP}:" "$CONF" | grep -q ' down;' && return 0
    else
      grep "server ${IP}:" "$CONF" | grep -qv ' down;' && return 0
    fi
    sleep 1
  done
  return 1
}

mark_intent() {   # 只改名单，不动配置文件
  local mode=$1
  if [ "$mode" = down ]; then grep -qx "$IP" "$MDOWN" || echo "$IP" >> "$MDOWN"
  else grep -vx "$IP" "$MDOWN" > "$MDOWN.tmp" 2>/dev/null || true; mv "$MDOWN.tmp" "$MDOWN"; fi
  if wait_hc "$mode"; then say "  已由健康检查（单一写入者）应用 ${mode} ${IP}，可用节点 $(active_count) 个"; return 0
  else say "  健康检查 15s 内未应用，退回直接改配置"; return 1; fi
}

main() {
  case "$ACT" in
    rollback)
      [ -n "$BK_ARG" ] || die "用法: lb-mark.sh <ip> rollback <备份文件>"
      restore_and_reload "$BK_ARG"; show; return 0 ;;
    status)
      say "manual_down.list: [$(tr '\n' ' ' < "$MDOWN" 2>/dev/null)]"
      say "可用节点: $(active_count)"
      show; return 0 ;;
  esac

  if ! grep -q "server ${IP}:" "$CONF"; then
    # 重启期间自动健康检查可能已把整个成员行删掉了。这时“去掉 down”无意义：
    # 只需把节点从人工下线名单里移除，剩下的交给健康检查（它探测通过会自己 ADD）。
    if [ "$ACT" = up ]; then
      grep -vx "$IP" "$MDOWN" > "$MDOWN.tmp" 2>/dev/null || true; mv "$MDOWN.tmp" "$MDOWN"
      say "  ${IP} 已不在 upstream 里（被自动健康检查移除了）；已从人工下线名单移除，等探测通过自动 ADD"
      show; return 0
    fi
    say "当前 upstream:"; show; die "${IP} 不在里面"
  fi

  # 有健康检查在跑 ⇒ 只写名单（避免两边各 reload 一次）
  if [ "${LB_VIA_HC:-auto}" != 0 ] && hc_running; then
    # 保护同样要先做：标 down 后可用节点不能低于 MIN_ACTIVE
    if [ "$ACT" = down ] && [ "$FORCE" != 1 ]; then
      local after2; after2=$(( $(active_count) - 1 ))
      [ "${after2}" -lt "${MIN_ACTIVE}" ] && die "这样只剩 ${after2} 个可用节点（< MIN_ACTIVE=${MIN_ACTIVE}）。确认请 FORCE=1"
    fi
    if mark_intent "$ACT"; then show; return 0; fi
  fi

  local new tmp after
  new=$(render "$ACT") || die "生成新配置失败"
  tmp="$UP_DIR/.mark.tmp"
  printf '%s\n' "$new" > "$tmp"

  # 保护必须在写 manual_down.list 之前
  after=$(grep 'server ' "$tmp" | grep -vc ' down;')
  if [ "${after}" -lt "${MIN_ACTIVE}" ] && [ "${FORCE}" != 1 ]; then
    rm -f "$tmp"
    die "这样只剩 ${after} 个可用节点（< MIN_ACTIVE=${MIN_ACTIVE}）。确认要这样请 FORCE=1"
  fi
  if cmp -s "$tmp" "$CONF"; then
    say "无变化（${IP} 已经是目标状态）"; rm -f "$tmp"
    [ "$ACT" = down ] && { grep -qx "$IP" "$MDOWN" || echo "$IP" >> "$MDOWN"; }
    show; return 0
  fi

  # 先登记意图（否则容器内的健康检查会在下一轮把改动覆盖回去），再改配置
  if [ "$ACT" = down ]; then grep -qx "$IP" "$MDOWN" || echo "$IP" >> "$MDOWN"
  else grep -vx "$IP" "$MDOWN" > "$MDOWN.tmp" 2>/dev/null || true; mv "$MDOWN.tmp" "$MDOWN"; fi

  local bk; bk=$(backup)
  mv "$tmp" "$CONF"                                     # 原子替换
  nginx_t
  case $? in
    0) : ;;
    1) say "  nginx -t 语法失败"; restore_and_reload "$bk"; die "配置语法错误，已回滚" ;;
    *) say "  连不上 LB（容器未就绪？）"; restore_and_reload "$bk"; die "LB 不可达，已回滚（未做变更）" ;;
  esac
  say "  reload nginx: ${ACT} ${IP}，可用节点 ${after} 个"
  nginx_reload || { say "  reload 失败"; restore_and_reload "$bk"; die "reload 失败，已回滚"; }
  sleep 1
  verify || { say "  reload 后探活失败"; restore_and_reload "$bk"; die "reload 后入口异常，已回滚"; }
  say "OK. 当前 upstream:"; show
}

# 串行化：整个 main 在锁内跑（macOS 无 flock 时退化为无锁）
exec 9>"$LOCK"
if command -v flock >/dev/null 2>&1; then flock -w 30 9 || die "拿不到锁（另一个维护操作在跑）"; fi
main
