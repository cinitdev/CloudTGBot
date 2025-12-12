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

    # 1. 安装基础依赖
    echo -e "${BLUE}[1/5] 检查并安装环境依赖...${PLAIN}"
    apt update -y
    apt install wget python3 file p7zip-full -y

    # 2. 准备目录
    if [ ! -d "$target_dir" ]; then
        echo -e "${BLUE}[2/5] 创建安装目录...${PLAIN}"
        mkdir -p "$target_dir"
    else
        echo -e "${YELLOW}[2/5] 检测到目录已存在，将直接覆盖更新文件...${PLAIN}"
    fi


    # 3. 下载文件
    echo -e "${BLUE}[3/5] 正在下载源码包...${PLAIN}"
    local zip_file="$target_dir/source.zip"
    
    # 增加超时参数，防止卡死
    wget --no-check-certificate -T 30 -t 3 -O "$zip_file" "$url"

    if [ ! -f "$zip_file" ]; then
        echo -e "${RED}❌ 下载失败，请检查链接是否正确！${PLAIN}"
        return 1
    fi

    # 检查文件类型 (防止下载成 404 网页)
    file_type=$(file -b --mime-type "$zip_file")
    if [[ "$file_type" != "application/zip" ]]; then
        echo -e "${RED}❌ 下载错误！${PLAIN}"
        echo -e "${YELLOW}下载到的不是 ZIP 包，而是: $file_type${PLAIN}"
        echo -e "可能原因：GitHub 链接不正确 (404 网页) 或 URL 包含特殊字符未转义。"
        rm -f "$zip_file"
        return 1
    fi

    # 4. 交互式密码验证与解压
    echo -e "${BLUE}[4/5] 准备解压...${PLAIN}"
    local zip_pass=""

    while true; do
        read -p "🔒 请输入 ZIP 压缩包密码: " -r zip_pass
        echo ""

        if [[ -z "$zip_pass" ]]; then
            echo -e "${RED}❌ 密码不能为空！${PLAIN}"
            continue
        fi
        
        if 7z t -p"$zip_pass" -y "$zip_file" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ 密码正确，开始解压...${PLAIN}"
            break
        else
            echo -e "${RED}❌ 密码错误，请重新输入！${PLAIN}"
        fi
    done

    7z x -p"$zip_pass" -y -o"$target_dir" "$zip_file" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 解压失败，请检查文件完整性。${PLAIN}"
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