#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Ubuntu VM 网络自动配置脚本
#
# 网络规划：
#   CLUSTER      VLAN32  10.99.32.X/24
#   VM-INTERNAL  VLAN40  10.99.40.X/24   可选
#   WEB-DMZ      VLAN41  10.99.41.X/24
#
# WEB-DMZ 为默认出口：
#   GW  = 10.99.41.1
#   DNS = 10.99.99.1
#
# 使用：
#   sudo ./vm-network.sh 23
#
# 直接应用：
#   sudo ./vm-network.sh 23 --apply
#
# 没有 VM-INTERNAL：
#   sudo ./vm-network.sh 23 --no-internal
#
# 手动指定接口：
#   sudo ./vm-network.sh 23 \
#       --cluster ens160 \
#       --internal ens192 \
#       --dmz ens224
# ============================================================

NETPLAN_FILE="/etc/netplan/99-vm-network.yaml"
DNS_SERVER="10.99.99.1"
SEARCH_DOMAIN="intra.duallee.com"

CLUSTER_NET="10.99.32"
INTERNAL_NET="10.99.40"
DMZ_NET="10.99.41"

INTERNAL_GW="10.99.40.1"
DMZ_GW="10.99.41.1"

APPLY=0
NO_INTERNAL=0

CLUSTER_IF=""
INTERNAL_IF=""
DMZ_IF=""

usage() {
    cat <<EOF
Usage:
  $0 <last_octet> [options]

Examples:
  $0 23
  $0 23 --apply
  $0 23 --no-internal
  $0 23 --cluster ens160 --internal ens192 --dmz ens224

Options:
  --cluster IFACE
  --internal IFACE
  --dmz IFACE
  --no-internal
  --apply
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

HOST_ID="$1"
shift

# -------------------------
# 检查主机号
# -------------------------
if ! [[ "$HOST_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: 最后一位必须是数字"
    exit 1
fi

if (( HOST_ID < 2 || HOST_ID > 254 )); then
    echo "ERROR: 地址数字建议使用 2-254"
    exit 1
fi

# -------------------------
# 参数处理
# -------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster)
            CLUSTER_IF="$2"
            shift 2
            ;;
        --internal)
            INTERNAL_IF="$2"
            shift 2
            ;;
        --dmz)
            DMZ_IF="$2"
            shift 2
            ;;
        --no-internal)
            NO_INTERNAL=1
            shift
            ;;
        --apply)
            APPLY=1
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# -------------------------
# 必须 root
# -------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: 请使用 sudo/root 运行"
    exit 1
fi

command -v netplan >/dev/null || {
    echo "ERROR: 系统没有安装 netplan"
    exit 1
}

# -------------------------
# 获取 VM 的物理/虚拟网卡
# 排除 lo/docker/veth/br/wg/tun 等
# -------------------------
mapfile -t NICS < <(
    for dev in /sys/class/net/*; do
        nic="$(basename "$dev")"

        [[ "$nic" == "lo" ]] && continue
        [[ "$nic" =~ ^docker ]] && continue
        [[ "$nic" =~ ^veth ]] && continue
        [[ "$nic" =~ ^br- ]] && continue
        [[ "$nic" =~ ^virbr ]] && continue
        [[ "$nic" =~ ^wg ]] && continue
        [[ "$nic" =~ ^tun ]] && continue
        [[ "$nic" =~ ^tap ]] && continue

        # VMware / virtio 等正常网卡通常存在 device
        [[ -e "$dev/device" ]] || continue

        echo "$nic"
    done | sort -V
)

echo
echo "检测到网卡："
for nic in "${NICS[@]}"; do
    MAC="$(cat "/sys/class/net/$nic/address" 2>/dev/null || true)"
    CARRIER="$(cat "/sys/class/net/$nic/carrier" 2>/dev/null || echo 0)"

    echo "  $nic   MAC=$MAC   carrier=$CARRIER"
done
echo

# -------------------------
# 自动映射
#
# 2 NIC:
#   #1 CLUSTER
#   #2 WEB-DMZ
#
# 3 NIC:
#   #1 CLUSTER
#   #2 VM-INTERNAL
#   #3 WEB-DMZ
#
# 前提：ESXi Network Adapter 顺序保持一致
# -------------------------

if [[ -z "$CLUSTER_IF" || -z "$DMZ_IF" ]]; then

    NIC_COUNT="${#NICS[@]}"

    if [[ "$NIC_COUNT" -eq 2 ]]; then

        [[ -z "$CLUSTER_IF" ]] && CLUSTER_IF="${NICS[0]}"
        [[ -z "$DMZ_IF" ]] && DMZ_IF="${NICS[1]}"

        NO_INTERNAL=1

    elif [[ "$NIC_COUNT" -eq 3 ]]; then

        [[ -z "$CLUSTER_IF" ]] && CLUSTER_IF="${NICS[0]}"
        [[ -z "$DMZ_IF" ]] && DMZ_IF="${NICS[2]}"

        if [[ "$NO_INTERNAL" -eq 0 && -z "$INTERNAL_IF" ]]; then
            INTERNAL_IF="${NICS[1]}"
        fi

    else
        echo "ERROR: 检测到 $NIC_COUNT 张网卡，无法安全自动判断角色。"
        echo
        echo "请手动指定，例如："
        echo "$0 $HOST_ID --cluster ens160 --internal ens192 --dmz ens224"
        exit 1
    fi
fi

if [[ "$NO_INTERNAL" -eq 1 ]]; then
    INTERNAL_IF=""
fi

# -------------------------
# 确认接口存在
# -------------------------
check_iface() {
    local iface="$1"

    [[ -z "$iface" ]] && return

    if [[ ! -e "/sys/class/net/$iface" ]]; then
        echo "ERROR: 网卡不存在: $iface"
        exit 1
    fi
}

check_iface "$CLUSTER_IF"
check_iface "$INTERNAL_IF"
check_iface "$DMZ_IF"

# 防止角色重复
if [[ "$CLUSTER_IF" == "$DMZ_IF" ]]; then
    echo "ERROR: CLUSTER 和 WEB-DMZ 不能是同一接口"
    exit 1
fi

if [[ -n "$INTERNAL_IF" ]]; then
    if [[ "$INTERNAL_IF" == "$CLUSTER_IF" ||
          "$INTERNAL_IF" == "$DMZ_IF" ]]; then
        echo "ERROR: VM-INTERNAL 与其他网卡重复"
        exit 1
    fi
fi

# -------------------------
# IP
# -------------------------

CLUSTER_IP="${CLUSTER_NET}.${HOST_ID}"
INTERNAL_IP="${INTERNAL_NET}.${HOST_ID}"
DMZ_IP="${DMZ_NET}.${HOST_ID}"

echo "============================================"
echo " 网络配置"
echo "============================================"
echo
echo "Host ID:"
echo "  ${HOST_ID}"
echo
echo "CLUSTER:"
echo "  IF  = ${CLUSTER_IF}"
echo "  IP  = ${CLUSTER_IP}/24"
echo
if [[ -n "$INTERNAL_IF" ]]; then
    echo "VM-INTERNAL:"
    echo "  IF  = ${INTERNAL_IF}"
    echo "  IP  = ${INTERNAL_IP}/24"
    echo "  GW  = ${INTERNAL_GW} (policy routing)"
    echo
else
    echo "VM-INTERNAL:"
    echo "  未配置"
    echo
fi
echo "WEB-DMZ:"
echo "  IF  = ${DMZ_IF}"
echo "  IP  = ${DMZ_IP}/24"
echo "  GW  = ${DMZ_GW}"
echo
echo "DNS:"
echo "  ${DNS_SERVER}"
echo

# -------------------------
# 备份现有 Netplan
# -------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/etc/netplan/backup-${STAMP}"

mkdir -p "$BACKUP_DIR"

shopt -s nullglob

for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ "$f" == "$NETPLAN_FILE" ]] && continue
    cp -a "$f" "$BACKUP_DIR/"
done

echo "Netplan backup:"
echo "  ${BACKUP_DIR}"

# -------------------------
# 如果使用 cloud-init
# 防止它重写网络
# -------------------------

if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<EOF
network:
  config: disabled
EOF
fi

# -------------------------
# 生成 Netplan
# -------------------------

cat > "$NETPLAN_FILE" <<EOF
# ============================================================
# Generated by vm-network.sh
# Host ID: ${HOST_ID}
# ============================================================

network:
  version: 2
  renderer: networkd

  ethernets:

    ${CLUSTER_IF}:
      dhcp4: false
      dhcp6: false
      optional: true
      addresses:
        - ${CLUSTER_IP}/24

EOF

# VM-INTERNAL 可选
if [[ -n "$INTERNAL_IF" ]]; then

cat >> "$NETPLAN_FILE" <<EOF
    ${INTERNAL_IF}:
      dhcp4: false
      dhcp6: false
      optional: true
      addresses:
        - ${INTERNAL_IP}/24

      routes:
        - to: ${INTERNAL_NET}.0/24
          scope: link
          table: 40

        - to: default
          via: ${INTERNAL_GW}
          table: 40
          on-link: true

      routing-policy:
        - from: ${INTERNAL_IP}/32
          table: 40
          priority: 100

EOF

fi

# WEB-DMZ
cat >> "$NETPLAN_FILE" <<EOF
    ${DMZ_IF}:
      dhcp4: false
      dhcp6: false
      optional: true
      addresses:
        - ${DMZ_IP}/24

      routes:
        - to: default
          via: ${DMZ_GW}
          metric: 100

      nameservers:
        addresses:
          - ${DNS_SERVER}
        search:
          - ${SEARCH_DOMAIN}
EOF

chmod 600 "$NETPLAN_FILE"

# -------------------------
# 多网卡服务器建议 loose rp_filter
# -------------------------

cat > /etc/sysctl.d/90-multihome-network.conf <<EOF
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF

sysctl --system >/dev/null

# -------------------------
# 验证语法
# -------------------------

echo
echo "生成配置："
echo "--------------------------------------------"
cat "$NETPLAN_FILE"
echo "--------------------------------------------"
echo

echo "执行 Netplan 语法检查..."

netplan generate

echo "Netplan 配置检查通过。"

# -------------------------
# 应用
# -------------------------

if [[ "$APPLY" -eq 1 ]]; then

    echo
    echo "正在应用网络配置..."
    netplan apply

    sleep 2

    echo
    echo "============================================"
    echo " 当前地址"
    echo "============================================"

    ip -br addr

    echo
    echo "============================================"
    echo " 主路由表"
    echo "============================================"

    ip route

    if [[ -n "$INTERNAL_IF" ]]; then
        echo
        echo "============================================"
        echo " VM-INTERNAL Policy Routing"
        echo "============================================"

        ip rule
        ip route show table 40
    fi

else

    echo
    echo "配置尚未正式应用。"
    echo
    echo "建议执行："
    echo
    echo "  netplan try"
    echo
    echo "确认网络正常后再保存。"
    echo
    echo "或者直接："
    echo
    echo "  $0 ${HOST_ID} --apply"
fi
