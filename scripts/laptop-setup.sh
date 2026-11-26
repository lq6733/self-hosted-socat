#!/usr/bin/env bash
# 客户端（朋友那台机器）的一键初始化：
#   拉取自签 CA → 校验证书链 → 装进系统信任库 → 装进浏览器 NSS → 写客户端环境变量 → 验活
#
#   ./laptop-setup.sh <服务器地址> [你的 API KEY] [端口]
#   例: ./laptop-setup.sh 100.x.y.z sk-xxxx 8443
#
# 环境变量: CPA_USER（SSH 用户名，默认当前用户）、CPA_CA_PATH（服务器上的 CA 路径）
set -uo pipefail

HOST="${1:-}"; API_KEY="${2:-}"; PORT="${3:-8443}"
CPA_USER="${CPA_USER:-$USER}"
CPA_CA_PATH="${CPA_CA_PATH:-.config/cliproxyapi/tls/ca.crt}"

[ -z "$HOST" ] && { echo "用法: $0 <服务器地址> [API KEY] [端口]"; exit 2; }
BASE="https://${HOST}:${PORT}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CA="$WORK/ca.crt"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

say "1/5  拉取服务器 CA"
scp -q "${CPA_USER}@${HOST}:${CPA_CA_PATH}" "$CA" \
  || die "scp 失败：先确认 ssh ${CPA_USER}@${HOST} 能登录"
ok "已获取 $(openssl x509 -in "$CA" -noout -subject | sed 's/subject=//')"
echo "     SHA-256: $(openssl x509 -in "$CA" -noout -fingerprint -sha256 | sed 's/.*=//')"

say "2/5  校验证书链（防中间人）"
served="$WORK/served.crt"
if echo | timeout 15 openssl s_client -connect "${HOST}:${PORT}" -servername "$HOST" 2>/dev/null \
     | openssl x509 -out "$served" 2>/dev/null && openssl verify -CAfile "$CA" "$served" >/dev/null 2>&1; then
  ok "服务器出示的证书确由该 CA 签发"
else
  die "证书链校验失败——CA 与服务器证书不匹配，可能被中间人替换，已中止"
fi

say "3/5  安装到系统信任库"
OSID="$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"')"
OSLIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release 2>/dev/null | tr -d '"')"
echo "  发行版: ${OSID:-unknown}${OSLIKE:+ (like: $OSLIKE)}"

trust_ok() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$BASE/v1/models" 2>/dev/null || true)"
  [ "$code" = "401" ] || [ "$code" = "200" ]
}
do_arch()   { sudo mkdir -p /etc/ca-certificates/trust-source/anchors \
              && sudo cp "$CA" /etc/ca-certificates/trust-source/anchors/cpa-local-ca.crt \
              && { sudo trust extract-compat >/dev/null 2>&1 || sudo update-ca-trust extract >/dev/null 2>&1 || true; }; }
do_debian() { sudo mkdir -p /usr/local/share/ca-certificates \
              && sudo cp "$CA" /usr/local/share/ca-certificates/cpa-local-ca.crt \
              && sudo update-ca-certificates >/dev/null 2>&1; }
do_redhat() { sudo mkdir -p /etc/pki/ca-trust/source/anchors \
              && sudo cp "$CA" /etc/pki/ca-trust/source/anchors/cpa-local-ca.crt \
              && sudo update-ca-trust >/dev/null 2>&1; }

case "$OSID" in
  arch|endeavouros|manjaro|cachyos|garuda) METHODS="do_arch do_debian do_redhat" ;;
  ubuntu|debian|linuxmint|pop|zorin|kali)  METHODS="do_debian do_arch do_redhat" ;;
  fedora|rhel|centos|rocky|alma)           METHODS="do_redhat do_arch do_debian" ;;
  *)                                        METHODS="do_arch do_debian do_redhat" ;;
esac

TRUSTED=no
for m in $METHODS; do
  if $m && trust_ok; then ok "系统信任库生效（$m）"; TRUSTED=yes; break; fi
done
[ "$TRUSTED" = no ] && warn "系统信任库未装成功，命令行改用 --cacert \$CPA_CA_FILE（脚本已配好）"

say "4/5  安装到浏览器（Chromium / Firefox）"
if ! command -v certutil >/dev/null 2>&1; then
  warn "未装 certutil，浏览器需手动导入（Debian/Ubuntu: sudo apt install -y libnss3-tools 后重跑本脚本）"
else
  nss_add() {
    local db="$1"
    mkdir -p "$db"
    [ -f "$db/cert9.db" ] || certutil -d "sql:$db" -N --empty-password >/dev/null 2>&1 || true
    certutil -d "sql:$db" -A -t "C,," -n "CPA Local CA" -i "$CA" >/dev/null 2>&1 \
      || certutil -d "sql:$db" -A -t "C,," -n "CPA Local CA $(date +%H%M%S)" -i "$CA" >/dev/null 2>&1
  }
  nss_add "$HOME/.pki/nssdb" && ok "Chromium / Chrome" || warn "Chromium 导入失败（可忽略）"
  ff=0
  for prof in "$HOME"/.mozilla/firefox/*/ "$HOME"/snap/firefox/common/.mozilla/firefox/*/ \
              "$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/; do
    [ -d "$prof" ] || continue
    nss_add "${prof%/}" && ff=$((ff+1))
  done
  [ "$ff" -gt 0 ] && ok "Firefox（$ff 个配置目录）" || warn "未找到 Firefox 配置目录"
fi

say "5/5  写入客户端配置并验活"
mkdir -p "$HOME/.config/cpa" && chmod 700 "$HOME/.config/cpa"
{
  echo "# 由 laptop-setup.sh 生成于 $(date '+%F %T')"
  echo "export ANTHROPIC_BASE_URL=$BASE"
  echo "export ANTHROPIC_AUTH_TOKEN=${API_KEY:-<填入你的 API KEY>}"
  echo "export OPENAI_BASE_URL=$BASE/v1"
  echo "export OPENAI_API_KEY=${API_KEY:-<填入你的 API KEY>}"
  echo "export CPA_CA_FILE=$HOME/.config/cpa/cpa-local-ca.crt"
} > "$HOME/.config/cpa/client.env"
chmod 600 "$HOME/.config/cpa/client.env"
cp "$CA" "$HOME/.config/cpa/cpa-local-ca.crt"
ok "已写入 ~/.config/cpa/client.env"

if [ -n "$API_KEY" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 --cacert "$CA" "$BASE/v1/models" \
          -H "Authorization: Bearer $API_KEY" || true)"
  case "$CODE" in
    200) ok "API KEY 可用（HTTP 200）" ;;
    401) die "HTTP 401：这把 API KEY 不被接受（拼错或已被吊销）" ;;
    000) die "TLS/连接失败：确认能 ssh ${CPA_USER}@${HOST}、且 ${PORT} 端口可达" ;;
    *)   die "HTTP $CODE：异常响应" ;;
  esac
else
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 15 --cacert "$CA" "$BASE/v1/models" || true)"
  ok "TLS 可通（HTTP $CODE，未带 key 时 401 属正常）"
fi

cat <<EOF

面板： $BASE/management.html
日常：
  source ~/.config/cpa/client.env
  curl --cacert \$CPA_CA_FILE \$OPENAI_BASE_URL/models -H "Authorization: Bearer \$OPENAI_API_KEY"

Claude Code 直接可用（它读 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN）。
EOF
