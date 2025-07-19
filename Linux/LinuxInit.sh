#!/bin/bash

# Error if not root
[ "$(id -u)" != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }

# Upgrade and install necessary packages
apt update && apt upgrade -y && apt autoremove -y
apt install -y openssl net-tools dnsutils nload curl wget lsof nano htop cron haveged vnstat chrony iftop iotop fail2ban unattended-upgrades unzip logrotate

# speedtest-cli
apt-get update && apt-get purge speedtest speedtest-cli -y
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
apt-get install speedtest -y

# Chrony configuration
cat > /etc/chrony/chrony.conf <<EOF
server 0.asia.pool.ntp.org iburst
server 1.asia.pool.ntp.org iburst
server 2.asia.pool.ntp.org iburst
server 3.asia.pool.ntp.org iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
log tracking measurements statistics
logdir /var/log/chrony
EOF

# Enable and verify chrony
systemctl enable --now chrony
chronyc tracking

# 等待chrony同步，最多等待60秒
for i in {1..12}; do
    status=$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs)
    if [[ "$status" == "Normal" ]]; then
        break
    fi
    sleep 5
done

# Timezone
timedatectl set-timezone Asia/Singapore

# Haveged
systemctl enable --now haveged

# Vnstat
systemctl enable --now vnstat

# Fail2ban
systemctl enable --now fail2ban

# unattended-upgrades 自动启用（自动安全更新，无交互）
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades 2>/dev/null || true

# logrotate 测试（可选，生产环境可省略）
# logrotate -f /etc/logrotate.conf

# Limits
# 备份所有 nproc.conf，防止默认限制覆盖自定义设置
for f in /etc/security/limits.d/*nproc.conf; do
    [ -e "$f" ] && mv "$f" "${f}_bk"
done

# 确保 pam_limits.so 被加载，否则 limits 配置不会生效
[ -f /etc/pam.d/common-session ] && [ -z "$(grep 'session required pam_limits.so' /etc/pam.d/common-session)" ] && echo "session required pam_limits.so" >> /etc/pam.d/common-session

# 网络服务优化 - 适度提升
cat > /etc/security/limits.d/99-network-limits.conf <<EOF
# 网络服务优化 - 适度提升
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768

root soft nofile 65536
root hard nofile 65536
root soft nproc 32768
root hard nproc 32768
EOF

# Sysctl
cat > /etc/sysctl.d/99-bbr-tun.conf <<'EOF'
# 1. 基础
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 缓冲区：32 MB 统一上限
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

# 3. 减少排队 & 丢包恢复
net.ipv4.tcp_mtu_probing = 1          # 开启 PLPMTUD，防中间设备黑洞
net.ipv4.tcp_fastopen = 3             # TFO 客户端+服务端
net.ipv4.tcp_slow_start_after_idle = 0 # 长连接不再降速
net.ipv4.tcp_notsent_lowat = 131072   # 降低 bufferbloat

# 4. 通用优化
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.core.netdev_max_backlog = 5000

# 5. 安全优化
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
# net.ipv4.ip_forward = 1               # 如果需要转发
EOF

# Apply sysctl settings
sysctl --system

# 检测磁盘大小
root_disk=$(df / --output=source | tail -1)
disk_device=$(lsblk -no pkname "$root_disk" 2>/dev/null | head -n1)
if [ -n "$disk_device" ]; then
    disk_device="/dev/$disk_device"
else
    disk_device="$root_disk"
fi
disk_size=$(lsblk -b -dn -o SIZE "$disk_device" 2>/dev/null | awk '{printf "%.2f GB", $1/1024/1024/1024}')

# 清屏
clear

# 输出验证配置
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 System Optimization Complete - Configuration Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-22s: %s\n" "BBR Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "%-22s: %s\n" "Queue Discipline" "$(sysctl -n net.core.default_qdisc)"
printf "%-22s: %s\n" "Open File Limit" "$(ulimit -n)"
printf "%-22s: %s\n" "Process Limit" "$(ulimit -u)"
printf "%-22s: %s\n" "Time Sync Status" "$(chronyc tracking 2>/dev/null | grep 'Leap status' | cut -d':' -f2 | xargs || echo 'Normal')"
printf "%-22s: %s\n" "Current Timezone" "$(timedatectl show --property=Timezone --value)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-22s: %s\n" "CPU Model" "$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)"
printf "%-22s: %s\n" "CPU Cores" "$(nproc)"
printf "%-22s: %s\n" "CPU MHz" "$(awk -F: '/cpu MHz/ {print $2; exit}' /proc/cpuinfo | xargs)"
printf "%-22s: %s\n" "Total RAM" "$(free -h | awk '/^Mem:/ {print $2}')"
printf "%-22s: %s\n" "Total Swap" "$(free -h | awk '/^Swap:/ {print $2}')"
printf "%-22s: %s\n" "Disk Size" "$disk_size"
printf "%-22s: %s\n" "OS Version" "$(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '\"')"
printf "%-22s: %s\n" "Kernel Version" "$(uname -r)"
printf "%-22s: %s\n" "Uptime" "$(uptime -p | cut -d' ' -f2-)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Package Install Status:"
for pkg in openssl net-tools dnsutils nload curl wget lsof nano htop cron haveged vnstat chrony iftop iotop fail2ban unattended-upgrades unzip logrotate speedtest; do
    if [ "$pkg" = "speedtest" ]; then
        if command -v speedtest &>/dev/null; then
            ver=$(speedtest --version 2>/dev/null | grep -o 'Speedtest by Ookla [0-9.]\+')
            printf "  %-20s: Installed (%s)\n" "$pkg" "$ver"
        else
            printf "  %-20s: Not Installed\n" "$pkg"
        fi
    else
        if dpkg -s "$pkg" &>/dev/null; then
            printf "  %-20s: Installed\n" "$pkg"
        else
            printf "  %-20s: Not Installed\n" "$pkg"
        fi
    fi
done
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Optimization complete! It is recommended to reboot the system for all settings to take effect."
echo ""
