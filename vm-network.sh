#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Ubuntu VM Network Auto Config
#
# 网络规划：
#
#   CLUSTER
#     VLAN32
#     10.99.32.X/24
#
#   VM-INTERNAL（可选）
#     VLAN40
#     10.99.40.X/24
#     GW 10.99.40.1
#     使用 Policy Routing 保证回程从 VLAN40 返回
#
#   WEB-DMZ
#     VLAN41
#     10.99.41.X/24
#     默认网关 10.99.41.1
#
#   Global DNS
#     10.99.99.1
#
# 使用示例：
#
#   三网卡：
#     sudo ./vm-network.sh 155 --apply
#
#   没有 VM-INTERNAL：
#     sudo ./vm-network.sh 155 --no-internal --apply
#
#   手动指定接口：
#     sudo ./vm-network.sh 155 \
#       --cluster ens160 \
#       --internal ens192 \
#       --dmz ens224 \
#       --apply
#
# GitHub：
# curl -fsSL URL | sudo bash -s -- 155 --apply
#
# ============================================================


# ------------------------------------------------------------
# 基础参数
# ------------------------------------------------------------

NETPLAN_FILE="/etc/netplan/99-vm-network.yaml"

DNS_SERVER="10.99.99.1"
SEARCH_DOMAIN="intra.duallee.com"

CLUSTER_NET="10.99.32"

INTERNAL_NET="10.99.40"
INTERNAL_GW="10.99.40.1"
INTERNAL_ROUTE_TABLE="140"

DMZ_NET="10.99.41"
DMZ_GW="10.99.41.1"

APPLY=0
NO_INTERNAL=0

CLUSTER_IF=""
INTERNAL_IF=""
DMZ_IF=""

HOST_ID=""


# ------------------------------------------------------------
# 函数
# ------------------------------------------------------------

usage() {
    cat <<EOF

Usage:

  $0 <IP最后一段> [参数]


示例：

  $0 155

  $0 155 --apply

  $0 155 --no-internal --apply

  $0 155 \
      --cluster ens160 \
      --internal ens192 \
      --dmz ens224 \
      --apply


参数：

  --cluster IFACE
      指定 CLUSTER / VLAN32 网卡

  --internal IFACE
      指定 VM-INTERNAL / VLAN40 网卡

  --dmz IFACE
      指定 WEB-DMZ / VLAN41 网卡

  --no-internal
      当前 VM 不使用 VM-INTERNAL

  --apply
      配置完成后立即执行 netplan apply

  -h / --help
      显示帮助

EOF

    exit 1
}


die() {
    echo
    echo "ERROR: $*" >&2
    echo
    exit 1
}


check_iface() {

    local iface="$1"

    [[ -z "$iface" ]] && return 0

    if [[ ! -e "/sys/class/net/${iface}" ]]; then
        die "找不到网卡：${iface}"
    fi
}


# ------------------------------------------------------------
# Root 检查
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 sudo 或 root 执行"
fi


# ------------------------------------------------------------
# 参数
# ------------------------------------------------------------

if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
    HOST_ID="$1"
    shift
fi


while [[ $# -gt 0 ]]; do

    case "$1" in

        --cluster)
            [[ $# -ge 2 ]] || die "--cluster 后需要接口名"
            CLUSTER_IF="$2"
            shift 2
            ;;

        --internal)
            [[ $# -ge 2 ]] || die "--internal 后需要接口名"
            INTERNAL_IF="$2"
            shift 2
            ;;

        --dmz)
            [[ $# -ge 2 ]] || die "--dmz 后需要接口名"
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

        -h|--help)
            usage
            ;;

        *)
            die "未知参数：$1"
            ;;

    esac

done


# ------------------------------------------------------------
# 没传 Host ID 时询问
# ------------------------------------------------------------

if [[ -z "$HOST_ID" ]]; then

    if [[ -e /dev/tty ]]; then
        read -rp "请输入服务器 IP 最后一段数字: " HOST_ID </dev/tty
    else
        die "没有指定 IP 最后一段"
    fi

fi


# ------------------------------------------------------------
# Host ID 检查
# ------------------------------------------------------------

if ! [[ "$HOST_ID" =~ ^[0-9]+$ ]]; then
    die "IP 最后一段必须是数字"
fi

if (( HOST_ID < 2 || HOST_ID > 254 )); then
    die "IP 最后一段必须在 2-254 之间"
fi


# ------------------------------------------------------------
# 检查必要程序
# ------------------------------------------------------------

command -v netplan >/dev/null 2>&1 || \
    die "系统未安装 netplan"

command -v ip >/dev/null 2>&1 || \
    die "系统缺少 iproute2"


# ------------------------------------------------------------
# 自动识别网卡
# ------------------------------------------------------------

mapfile -t NICS < <(

    for dev in /sys/class/net/*; do

        nic="$(basename "$dev")"

        case "$nic" in
            lo|docker*|veth*|br-*|virbr*|wg*|tun*|tap*|utun*)
                continue
                ;;
        esac

        # VMware / VirtIO / 实体 NIC 一般存在 device
        [[ -e "${dev}/device" ]] || continue

        echo "$nic"

    done | sort -V

)


NIC_COUNT="${#NICS[@]}"


echo
echo "============================================================"
echo " 检测到的网卡"
echo "============================================================"
echo


if (( NIC_COUNT == 0 )); then
    die "没有检测到可用网卡"
fi


for nic in "${NICS[@]}"; do

    MAC="$(cat "/sys/class/net/${nic}/address" 2>/dev/null || echo unknown)"
    CARRIER="$(cat "/sys/class/net/${nic}/carrier" 2>/dev/null || echo 0)"

    printf "  %-12s MAC=%-18s LINK=%s\n" \
        "$nic" "$MAC" "$CARRIER"

done


echo


# ------------------------------------------------------------
# 自动分配网卡角色
#
# 3张：
#   第一张 -> VLAN32
#   第二张 -> VLAN40
#   第三张 -> VLAN41
#
# 2张：
#   第一张 -> VLAN32
#   第二张 -> VLAN41
# ------------------------------------------------------------


if [[ -z "$CLUSTER_IF" ]]; then
    CLUSTER_IF="${NICS[0]}"
fi


if (( NO_INTERNAL == 1 )); then

    INTERNAL_IF=""

    if [[ -z "$DMZ_IF" ]]; then

        if (( NIC_COUNT < 2 )); then
            die "至少需要两张网卡"
        fi

        DMZ_IF="${NICS[$((NIC_COUNT - 1))]}"

    fi

else

    if (( NIC_COUNT >= 3 )); then

        if [[ -z "$INTERNAL_IF" ]]; then
            INTERNAL_IF="${NICS[1]}"
        fi

        if [[ -z "$DMZ_IF" ]]; then
            DMZ_IF="${NICS[$((NIC_COUNT - 1))]}"
        fi

    elif (( NIC_COUNT == 2 )); then

        echo "INFO: 只检测到两张网卡，自动关闭 VM-INTERNAL"

        INTERNAL_IF=""
        NO_INTERNAL=1

        if [[ -z "$DMZ_IF" ]]; then
            DMZ_IF="${NICS[1]}"
        fi

    else
        die "只有一张网卡，无法配置 CLUSTER + WEB-DMZ"
    fi

fi


# ------------------------------------------------------------
# 接口检查
# ------------------------------------------------------------

check_iface "$CLUSTER_IF"
check_iface "$INTERNAL_IF"
check_iface "$DMZ_IF"


if [[ "$CLUSTER_IF" == "$DMZ_IF" ]]; then
    die "CLUSTER 和 WEB-DMZ 不能使用同一张网卡"
fi


if [[ -n "$INTERNAL_IF" ]]; then

    if [[ "$INTERNAL_IF" == "$CLUSTER_IF" ]]; then
        die "VM-INTERNAL 和 CLUSTER 接口重复"
    fi

    if [[ "$INTERNAL_IF" == "$DMZ_IF" ]]; then
        die "VM-INTERNAL 和 WEB-DMZ 接口重复"
    fi

fi


# ------------------------------------------------------------
# IP
# ------------------------------------------------------------

CLUSTER_IP="${CLUSTER_NET}.${HOST_ID}"
INTERNAL_IP="${INTERNAL_NET}.${HOST_ID}"
DMZ_IP="${DMZ_NET}.${HOST_ID}"


echo
echo "============================================================"
echo " 即将配置"
echo "============================================================"

echo
echo "服务器编号：${HOST_ID}"
echo

echo "CLUSTER / VLAN32"
echo "  Interface : ${CLUSTER_IF}"
echo "  Address   : ${CLUSTER_IP}/24"
echo


if [[ -n "$INTERNAL_IF" ]]; then

    echo "VM-INTERNAL / VLAN40"
    echo "  Interface : ${INTERNAL_IF}"
    echo "  Address   : ${INTERNAL_IP}/24"
    echo "  Gateway   : ${INTERNAL_GW}（Policy Routing）"
    echo

else

    echo "VM-INTERNAL / VLAN40"
    echo "  未启用"
    echo

fi


echo "WEB-DMZ / VLAN41"
echo "  Interface : ${DMZ_IF}"
echo "  Address   : ${DMZ_IP}/24"
echo "  Gateway   : ${DMZ_GW}"
echo

echo "Global DNS"
echo "  ${DNS_SERVER}"
echo


# ------------------------------------------------------------
# 备份现有 Netplan
# ------------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"

BACKUP_DIR="/etc/netplan/backup-${STAMP}"

mkdir -p "$BACKUP_DIR"


shopt -s nullglob

OLD_NETPLAN_FILES=(
    /etc/netplan/*.yaml
    /etc/netplan/*.yml
)


if (( ${#OLD_NETPLAN_FILES[@]} > 0 )); then

    echo "备份旧 Netplan 到："
    echo "  ${BACKUP_DIR}"

    for f in "${OLD_NETPLAN_FILES[@]}"; do

        echo "  备份 $(basename "$f")"

        cp -a "$f" "$BACKUP_DIR/"

    done

fi


# ------------------------------------------------------------
# 删除旧活动 Netplan
#
# 避免 50-cloud-init.yaml 和新配置同时加载
# ------------------------------------------------------------

rm -f /etc/netplan/*.yaml
rm -f /etc/netplan/*.yml


# ------------------------------------------------------------
# Cloud-init 禁止重新生成网络
# ------------------------------------------------------------

mkdir -p /etc/cloud/cloud.cfg.d

cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF


# ------------------------------------------------------------
# 生成 Netplan
# ------------------------------------------------------------

cat > "$NETPLAN_FILE" <<EOF
# ============================================================
# Generated by vm-network.sh
#
# Host ID:
#   ${HOST_ID}
#
# DO NOT edit cloud-init network file.
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


# ------------------------------------------------------------
# VLAN40
#
# 用 Source Policy Routing：
#
# 如果外部 VLAN 访问 10.99.40.X，
# 回复仍然通过 10.99.40.1 / VLAN40 返回。
#
# 否则多网卡主机可能从 VLAN41 默认路由回包。
# ------------------------------------------------------------

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
          table: ${INTERNAL_ROUTE_TABLE}

        - to: 0.0.0.0/0
          via: ${INTERNAL_GW}
          table: ${INTERNAL_ROUTE_TABLE}
          on-link: true

      routing-policy:

        - from: ${INTERNAL_IP}/32
          table: ${INTERNAL_ROUTE_TABLE}
          priority: 1040

EOF

fi


# ------------------------------------------------------------
# VLAN41
#
# 唯一主默认网关
# ------------------------------------------------------------

cat >> "$NETPLAN_FILE" <<EOF
    ${DMZ_IF}:
      dhcp4: false
      dhcp6: false
      optional: true
      addresses:
        - ${DMZ_IP}/24

      routes:

        - to: 0.0.0.0/0
          via: ${DMZ_GW}
          metric: 100
EOF


chmod 600 "$NETPLAN_FILE"


# ------------------------------------------------------------
# Netplan 语法检查
# ------------------------------------------------------------

echo
echo "============================================================"
echo " Netplan 配置"
echo "============================================================"
echo

cat "$NETPLAN_FILE"

echo
echo "正在执行 netplan generate ..."


if ! netplan generate; then

    echo
    echo "ERROR: Netplan 配置检查失败"
    echo "正在恢复原配置..."

    rm -f /etc/netplan/*.yaml
    rm -f /etc/netplan/*.yml

    cp -a "${BACKUP_DIR}/." /etc/netplan/ 2>/dev/null || true

    netplan generate 2>/dev/null || true

    die "已恢复旧 Netplan"

fi


echo "Netplan 语法检查通过。"


# ------------------------------------------------------------
# 多网卡 rp_filter
#
# loose mode：
#
# 0 = 禁用
# 1 = strict
# 2 = loose
#
# 多网卡环境推荐 2
# ------------------------------------------------------------

cat > /etc/sysctl.d/90-multihome-network.conf <<'EOF'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF


sysctl --system >/dev/null


# ------------------------------------------------------------
# Global DNS
#
# 持久化：
#
#   /etc/systemd/resolved.conf.d/
#
# 重启后依然存在。
# ------------------------------------------------------------

if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved.service'; then

    mkdir -p /etc/systemd/resolved.conf.d

    cat > /etc/systemd/resolved.conf.d/10-global-dns.conf <<EOF
[Resolve]

DNS=${DNS_SERVER}

FallbackDNS=

Domains=~. ${SEARCH_DOMAIN}

LLMNR=no
MulticastDNS=no
EOF


    # Ubuntu 标准 systemd-resolved Stub
    ln -sf \
        /run/systemd/resolve/stub-resolv.conf \
        /etc/resolv.conf


    systemctl enable systemd-resolved >/dev/null 2>&1 || true

    systemctl restart systemd-resolved

else

    echo
    echo "WARNING:"
    echo "  未检测到 systemd-resolved"
    echo "  Global DNS 未自动配置"

fi


# ------------------------------------------------------------
# 应用
# ------------------------------------------------------------

if (( APPLY == 1 )); then

    echo
    echo "============================================================"
    echo " 正在应用 Netplan"
    echo "============================================================"
    echo

    netplan apply

    sleep 3


    echo
    echo "============================================================"
    echo " IP 地址"
    echo "============================================================"
    echo

    ip -br addr


    echo
    echo "============================================================"
    echo " 主路由表"
    echo "============================================================"
    echo

    ip route


    echo
    echo "============================================================"
    echo " Policy Rules"
    echo "============================================================"
    echo

    ip rule


    if [[ -n "$INTERNAL_IF" ]]; then

        echo
        echo "============================================================"
        echo " VLAN40 Policy Route Table ${INTERNAL_ROUTE_TABLE}"
        echo "============================================================"
        echo

        ip route show table "$INTERNAL_ROUTE_TABLE"

    fi


    echo
    echo "============================================================"
    echo " Global DNS"
    echo "============================================================"
    echo

    if command -v resolvectl >/dev/null 2>&1; then

        resolvectl status | sed -n '1,30p'

    else

        cat /etc/resolv.conf

    fi


    echo
    echo "============================================================"
    echo " 网络测试"
    echo "============================================================"
    echo


    echo "[1] WEB-DMZ Gateway"
    if ping -c 1 -W 2 "$DMZ_GW" >/dev/null 2>&1; then
        echo "  OK   ${DMZ_GW}"
    else
        echo "  FAIL ${DMZ_GW}"
    fi


    echo
    echo "[2] DNS Server"
    if ping -c 1 -W 2 "$DNS_SERVER" >/dev/null 2>&1; then
        echo "  OK   ${DNS_SERVER}"
    else
        echo "  FAIL ${DNS_SERVER}"
    fi


    echo
    echo "[3] DNS Resolve"

    if getent hosts www.baidu.com >/dev/null 2>&1; then

        echo "  OK   DNS解析正常"

        getent hosts www.baidu.com | head -3

    else

        echo "  FAIL DNS解析失败"
        echo
        echo "  请确认 iStoreOS dnsmasq 已监听："
        echo "    vlan20"
        echo "    vlan40"
        echo "    vlan41"

    fi


    echo
    echo "============================================================"
    echo " 配置完成"
    echo "============================================================"
    echo

    echo "CLUSTER:"
    echo "  ${CLUSTER_IF} = ${CLUSTER_IP}/24"

    if [[ -n "$INTERNAL_IF" ]]; then

        echo
        echo "VM-INTERNAL:"
        echo "  ${INTERNAL_IF} = ${INTERNAL_IP}/24"

    fi

    echo
    echo "WEB-DMZ:"
    echo "  ${DMZ_IF} = ${DMZ_IP}/24"
    echo "  Default GW = ${DMZ_GW}"

    echo
    echo "DNS:"
    echo "  ${DNS_SERVER}"

    echo
    echo "Netplan:"
    echo "  ${NETPLAN_FILE}"

    echo
    echo "Backup:"
    echo "  ${BACKUP_DIR}"

    echo

else

    echo
    echo "============================================================"
    echo " 配置已生成，但尚未 Apply"
    echo "============================================================"
    echo

    echo "建议先检查："
    echo
    echo "  cat ${NETPLAN_FILE}"
    echo
    echo "然后执行："
    echo
    echo "  sudo netplan try"
    echo
    echo "或者直接重新运行："
    echo
    echo "  $0 ${HOST_ID} --apply"
    echo

fi
