#!/bin/bash
# 脚本功能：
# 从随机老婆图片生成 API 下载图片并使用 Fastfetch 展示。
# 特性：支持 NSFW 模式，支持自动补货，支持已用图片归档与自动清理，支持终端关闭后继续后台补货。

# ================= 配置区域 =================

# [开关] 强力清理 Fastfetch 内部缓存
# true  = 每次运行后清理 ~/.cache/fastfetch/images/ (防止转码缓存膨胀)
# false = 保留 Fastfetch 内部缓存
CLEAN_CACHE_MODE=true

# 每次补货下载多少张
DOWNLOAD_BATCH_SIZE=10
# 最大库存上限 (待展示区)
MAX_CACHE_LIMIT=100
# 库存少于多少张时开始补货
MIN_TRIGGER_LIMIT=60

# used 目录最大存放数量
# 超过此数量将按照时间顺序删除最旧的文件
MAX_USED_LIMIT=50

# ===========================================

# --- 0. 参数解析与模式设置 ---

NSFW_MODE=false
# 检查环境变量
if [ "$NSFW" = "1" ]; then
    NSFW_MODE=true
fi

ARGS_FOR_FASTFETCH=()
for arg in "$@"; do
    if [ "$arg" == "--nsfw" ]; then
        NSFW_MODE=true
    else
        ARGS_FOR_FASTFETCH+=("$arg")
    fi
done

# --- 1. 目录配置 ---

# 根据模式区分缓存目录和锁文件
if [ "$NSFW_MODE" = true ]; then
    CACHE_DIR="$HOME/.cache/fastfetch_waifu_nsfw"
    LOCK_FILE="/tmp/fastfetch_waifu_nsfw.lock"
else
    CACHE_DIR="$HOME/.cache/fastfetch_waifu"
    LOCK_FILE="/tmp/fastfetch_waifu.lock"
fi

# 定义已使用目录
USED_DIR="$CACHE_DIR/used"

mkdir -p "$CACHE_DIR"
mkdir -p "$USED_DIR"

# --- 2. 核心函数 ---

# [新增] 网络连通性检测，防止没网时阻塞终端或后台死等
check_network() {
    curl -s --connect-timeout 2 "https://1.1.1.1" >/dev/null 2>&1
    return $?
}

get_random_url() {
    local TIMEOUT="--connect-timeout 5 --max-time 15"
    RAND=$(( ( RANDOM % 3 ) + 1 ))
    
    if [ "$NSFW_MODE" = true ]; then
        # === NSFW API ===
        case $RAND in
            1) curl -s $TIMEOUT "https://api.waifu.im/search?included_tags=waifu&is_nsfw=true" | jq -r '.images[0].url' ;;
            2) curl -s $TIMEOUT "https://api.waifu.pics/nsfw/waifu" | jq -r '.url' ;;
            3) curl -s $TIMEOUT "https://api.waifu.pics/nsfw/neko" | jq -r '.url' ;;
        esac
    else
        # === SFW (正常) API ===
        case $RAND in
            1) curl -s $TIMEOUT "https://api.waifu.im/search?included_tags=waifu&is_nsfw=false" | jq -r '.images[0].url' ;;
            2) curl -s $TIMEOUT "https://nekos.best/api/v2/waifu" | jq -r '.results[0].url' ;;
            3) curl -s $TIMEOUT "https://api.waifu.pics/sfw/waifu" | jq -r '.url' ;;
        esac
    fi
}

download_one_image() {
    URL=$(get_random_url)
    if [[ "$URL" =~ ^http ]]; then
        # 使用带时间戳的随机文件名
        FILENAME="waifu_$(date +%s%N)_$RANDOM.jpg"
        TARGET_PATH="$CACHE_DIR/$FILENAME"
        
        curl -s -L --connect-timeout 5 --max-time 15 -o "$TARGET_PATH" "$URL"
        
        # 简单校验
        if [ -s "$TARGET_PATH" ]; then
            if command -v file >/dev/null 2>&1; then
                if ! file --mime-type "$TARGET_PATH" | grep -q "image/"; then
                    rm -f "$TARGET_PATH"
                fi
            fi
        else
            rm -f "$TARGET_PATH"
        fi
    fi
}

background_job() {
    (
        # [核心修复 1] 忽略终端关闭带来的 SIGHUP 信号
        trap '' HUP
        
        flock -n 200 || exit 1
        
        # [新增] 网络检查，没网就悄悄退出，不占后台资源
        if ! check_network; then
            exit 0
        fi
        
        # 1. 补货检查
        CURRENT_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)

        if [ "$CURRENT_COUNT" -lt "$MIN_TRIGGER_LIMIT" ]; then
            for ((i=1; i<=DOWNLOAD_BATCH_SIZE; i++)); do
                download_one_image
                sleep 0.5
            done
        fi

        # 2. 清理过多库存
        FINAL_COUNT=$(find "$CACHE_DIR" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)
        if [ "$FINAL_COUNT" -gt "$MAX_CACHE_LIMIT" ]; then
             DELETE_START_LINE=$((MAX_CACHE_LIMIT + 1))
             ls -tp "$CACHE_DIR"/*.jpg 2>/dev/null | tail -n +$DELETE_START_LINE | xargs -I {} rm -- "{}"
        fi
        
    ) 200>"$LOCK_FILE"
}

# --- 3. 主程序逻辑 ---

shopt -s nullglob
FILES=("$CACHE_DIR"/*.jpg)
NUM_FILES=${#FILES[@]}
shopt -u nullglob

SELECTED_IMG=""

if [ "$NUM_FILES" -gt 0 ]; then
    # 有库存，随机选一张
    RAND_INDEX=$(( RANDOM % NUM_FILES ))
    SELECTED_IMG="${FILES[$RAND_INDEX]}"
    
    # 后台补货
    background_job >/dev/null 2>&1 &
    # [核心修复 2] 将任务从终端作业列表中移除，脱离终端控制
    disown 
    
else
    # 没库存，提示语更改
    echo "库存不够啦！正在去搬运新的图片，请稍等哦..."
    
    # 无网情况下的容错处理
    if check_network; then
        download_one_image
    else
        echo "网络好像不太通畅，无法下载新图片 QAQ"
    fi
    
    shopt -s nullglob
    FILES=("$CACHE_DIR"/*.jpg)
    shopt -u nullglob
    
    if [ ${#FILES[@]} -gt 0 ]; then
        SELECTED_IMG="${FILES[0]}"
        background_job >/dev/null 2>&1 &
        # [核心修复 2] 将任务从终端作业列表中移除
        disown 
    fi
fi

# 运行 Fastfetch
if [ -n "$SELECTED_IMG" ] && [ -f "$SELECTED_IMG" ]; then
    
    # 显示图片
    fastfetch --logo "$SELECTED_IMG" --logo-preserve-aspect-ratio true "${ARGS_FOR_FASTFETCH[@]}"
    
    # === 逻辑：移动到 used 目录 ===
    mv "$SELECTED_IMG" "$USED_DIR/"
    
    # === 逻辑：检查 used 目录数量并清理 ===
    USED_COUNT=$(find "$USED_DIR" -maxdepth 1 -name "*.jpg" 2>/dev/null | wc -l)
    
    if [ "$USED_COUNT" -gt "$MAX_USED_LIMIT" ]; then
        # 计算需要保留的文件行数 (跳过最新的 MAX_USED_LIMIT 个)
        SKIP_LINES=$((MAX_USED_LIMIT + 1))
        # ls -tp 按时间倒序排列(新->旧)，tail 取出旧文件，xargs 删除
        ls -tp "$USED_DIR"/*.jpg 2>/dev/null | tail -n +$SKIP_LINES | xargs -I {} rm -- "{}"
    fi

    # 检查是否开启清理 Fastfetch 内部缓存 (仅清理缩略图缓存，不删原图)
    if [ "$CLEAN_CACHE_MODE" = true ]; then
        rm -rf "$HOME/.cache/fastfetch/images"
    fi
else
    # 失败提示语更改
    echo "呜呜... 图片获取失败了，这次只能先显示默认的 Logo 啦 QAQ"
    fastfetch "${ARGS_FOR_FASTFETCH[@]}"
fi
