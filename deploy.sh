#!/bin/bash

# ==========================================
# 多 Bot 一键部署管理器 (install.py 版)
# 功能：下载 ZIP -> 密码验证 -> 自定义目录 -> 解压 -> Python 安装
# ==========================================

# --- 基础配置与颜色 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 检查 Root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 权限运行此脚本。${PLAIN}"
   echo -e "请使用: sudo bash $0"
   exit 1
fi

# --- 核心部署函数 ---
# 参数1: 默认安装绝对路径 (例如 /root/TG_ShuaTie)
# 参数2: 项目显示名称
# 参数3: 下载链接
deploy_from_zip() {
    local default_path=$1
    local app_name=$2
    local url=$3
    local target_dir=""

    echo -e "${GREEN}>>> 正在准备部署: ${app_name}${PLAIN}"
    echo -e "${YELLOW}------------------------------------------------${PLAIN}"
    echo -e "📂 确认安装目录"
    read -p "   [回车使用默认: ${default_path}]: " user_input_path
    echo -e "${YELLOW}------------------------------------------------${PLAIN}"

    if [[ -z "$user_input_path" ]]; then
        target_dir="$default_path"
    else
        target_dir="$user_input_path"
    fi

    echo -e "${BLUE}➜ 目标路径: ${target_dir}${PLAIN}"

    # 1. 安装基础依赖 (新增 python3)
    echo -e "${BLUE}[1/5] 检查并安装环境依赖...${PLAIN}"
    apt update
    apt install -y wget unzip python3

    # 2. 清理与创建目录
    if [ -d "$target_dir" ]; then
        echo -e "${YELLOW}[2/5] 检测到旧目录，正在清理...${PLAIN}"
        rm -rf "$target_dir"
    fi
    mkdir -p "$target_dir"

    # 3. 下载文件
    echo -e "${BLUE}[3/5] 正在下载源码包...${PLAIN}"
    local zip_file="$target_dir/source.zip"
    wget -O "$zip_file" "$url" --no-check-certificate

    if [ ! -f "$zip_file" ]; then
        echo -e "${RED}❌ 下载失败，请检查链接是否正确！${PLAIN}"
        return 1
    fi

    # 4. 交互式密码验证与解压
    echo -e "${BLUE}[4/5] 准备解压...${PLAIN}"
    local zip_pass=""

    while true; do
        echo -n "🔒 请输入 ZIP 压缩包密码 (输入不显示): "
        read -s zip_pass
        echo ""

        if unzip -P "$zip_pass" -tq "$zip_file" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 密码正确，开始解压...${PLAIN}"
            break
        else
            echo -e "${RED}❌ 密码错误，请重新输入！${PLAIN}"
        fi
    done

    unzip -P "$zip_pass" -o "$zip_file" -d "$target_dir" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 解压失败。${PLAIN}"
        rm -f "$zip_file"
        return 1
    fi
    rm -f "$zip_file"

    # 5. 处理目录结构 (查找 install.py)
    # 如果解压后根目录没有 install.py，但子目录有，则移动出来
    if [ ! -f "$target_dir/install.py" ]; then
        sub_dir=$(find "$target_dir" -name "install.py" -exec dirname {} \;)
        if [ -n "$sub_dir" ] && [ "$sub_dir" != "$target_dir" ]; then
            echo -e "${YELLOW}检测到子目录结构，自动调整文件位置...${PLAIN}"
            mv "$sub_dir"/* "$target_dir/"
            rm -rf "$sub_dir"
        fi
    fi

    # 6. 运行 Python 安装脚本
    if [ -f "$target_dir/install.py" ]; then
        echo -e "${BLUE}[5/5] 开始执行 Python 安装脚本...${PLAIN}"
        echo -e "${YELLOW}>>> 转交控制权给 install.py ...${PLAIN}"
        echo ""
        cd "$target_dir"
        # 直接使用 python3 运行 install.py install
        python3 install.py install
    else
        echo -e "${RED}❌ 错误：压缩包内未找到 install.py！${PLAIN}"
        return 1
    fi
}

# ==========================================
#              菜 单 配 置 区
# ==========================================

show_menu() {
    clear
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "${GREEN}       Telegram Bot 集群部署管理器           ${PLAIN}"
    echo -e "${GREEN}=============================================${PLAIN}"
    echo -e "1. 部署 [Telegram 频道浏览监控Bot]"
    echo -e "2. 部署 [其他 Bot] (示例)"
    echo -e "0. 退出脚本"
    echo -e "${GREEN}=============================================${PLAIN}"
    read -p "请输入数字选择: " choice

    case $choice in
        1)
            DIR="/root/TG_ShuaTie"
            NAME="Telegram 频道浏览监控Bot"
            URL="https://raw.githubusercontent.com/cinitdev/CloudTGBot/refs/heads/master/协议号浏览频道/bot.zip"
            deploy_from_zip "$DIR" "$NAME" "$URL"
            ;;
        2)
            DIR="/opt/Other_Bot"
            NAME="示例机器人"
            URL="https://example.com/other.zip"

            deploy_from_zip "$DIR" "$NAME" "$URL"
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择${PLAIN}"
            ;;
    esac
}

show_menu