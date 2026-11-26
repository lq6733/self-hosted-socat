#!/usr/bin/env bash
# 生成自签名 CA + 服务器证书（用于 socat 在 tailnet 上提供 TLS）
#
#   ./cpa-gen-cert.sh --name node.tailxxxx.ts.net --ip 100.x.y.z [--ip 192.168.1.10] [--days 3650]
#
# 输出到 $CPA_TLS_DIR（默认 ~/.config/cliproxyapi/tls）：
#   ca.crt / ca.key          本地 CA（ca.key 只留在服务器，不要把私钥分发出去）
#   server.crt / server.key  服务器证书
#   fullchain.pem            leaf + CA，给 socat 的 cert= 用
set -euo pipefail

NAME="" ; IPS=() ; DAYS=3650
OUT="${CPA_TLS_DIR:-$HOME/.config/cliproxyapi/tls}"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --ip)   IPS+=("$2"); shift 2 ;;
    --days) DAYS="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -z "$NAME" ] && { echo "必须用 --name 指定主域名（tailnet 的 DNS name 或任意名字）" >&2; exit 2; }

mkdir -p "$OUT"; chmod 700 "$OUT"; cd "$OUT"

# 1) 本地 CA
if [ ! -f ca.crt ] || [ ! -f ca.key ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days "$DAYS" \
    -keyout ca.key -out ca.crt -subj "/CN=CPA Local CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  echo "已生成 CA: $OUT/ca.crt"
else
  echo "复用已有 CA: $OUT/ca.crt"
fi

# 2) SAN 列表
SAN="DNS:$NAME,DNS:localhost,IP:127.0.0.1"
for ip in "${IPS[@]:-}"; do [ -n "$ip" ] && SAN="$SAN,IP:$ip"; done

cat > san.cnf <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SAN
EOF

# 3) 服务器证书（用 CA 签发）
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 \
  -keyout server.key -out server.csr -subj "/CN=$NAME" 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days "$DAYS" -sha256 -extfile san.cnf 2>/dev/null
cat server.crt ca.crt > fullchain.pem

chmod 600 ca.key server.key
chmod 644 ca.crt server.crt fullchain.pem san.cnf
rm -f server.csr ca.srl

echo
echo "SAN: $SAN"
openssl verify -CAfile ca.crt server.crt
echo
echo "CA 指纹（客户端导入时核对）:"
openssl x509 -in ca.crt -noout -fingerprint -sha256 | sed 's/.*=//'
echo
echo "注意: ca.key 只留在服务器，只需把 ca.crt 分发给客户端。"
