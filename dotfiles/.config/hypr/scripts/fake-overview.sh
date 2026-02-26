#!/bin/bash

STATE_FILE="/tmp/hypr_fake_overview_state"
SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

# ==========================================
# 1. 再次按键时取消 (Toggle 逻辑)
# ==========================================
# 如果状态文件存在，说明 Fake Overview 正在运行，此时用户的意图是“取消”
if [ -f "$STATE_FILE" ]; then
    # 读取上次保存的布局和进程信息
    source "$STATE_FILE"
    
    # 恢复原本的布局
    hyprctl keyword workspace "$SAVED_WS, layout:$SAVED_LAYOUT" > /dev/null
    
    # 删除状态文件
    rm -f "$STATE_FILE"
    
    # 彻底清理战场：杀掉上一个脚本启动的 socat 和它本身，防止后台残留
    pkill -P "$OLD_SCRIPT_PID" socat 2>/dev/null
    kill "$OLD_SCRIPT_PID" 2>/dev/null
    
    exit 0
fi

# ==========================================
# 2. 启动 Fake Overview
# ==========================================
current_layout=$(hyprctl getoption general:layout | grep "str:" | awk '{print $2}')
if [ "$current_layout" == "dwindle" ]; then
    exit 0
fi

current_ws=$(hyprctl activeworkspace | head -n 1 | awk '{print $3}')

# 保存当前状态，供再次按下快捷键时 Toggle 恢复使用
# 这里把当前脚本的 PID ($$) 也存下来，方便取消时精准击杀
echo "SAVED_WS=$current_ws" > "$STATE_FILE"
echo "SAVED_LAYOUT=$current_layout" >> "$STATE_FILE"
echo "OLD_SCRIPT_PID=$$" >> "$STATE_FILE"

# 切换到 dwindle
hyprctl keyword workspace "$current_ws, layout:dwindle" > /dev/null

# 【关键细节】休眠 0.1 秒
# 为什么要休眠？因为切换布局瞬间，窗口会大挪移，如果有窗口刚好滑到了你的鼠标指针底下，
# Hyprland 会立即触发一次虚假的“焦点切换”事件，导致概览瞬间闪退。
sleep 0.1

# ==========================================
# 3. 实时监听事件 (解决需要切换两次的 Bug)
# ==========================================
# 抛弃 grep，改用 while 逐行读取，掌控绝对的控制权
socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null | while read -r line; do
    if [[ "$line" =~ ^(activewindowv2>>|focusedmon>>) ]]; then
        
        # 如果状态文件还在（没有被用户的第二次按键清理掉）
        if [ -f "$STATE_FILE" ]; then
            # 恢复原布局并清理文件
            hyprctl keyword workspace "$current_ws, layout:$current_layout" > /dev/null
            rm -f "$STATE_FILE"
        fi
        
        # 【核心杀招】一听到事件，立刻精准击杀挂在当前脚本下的 socat 进程！
        # 管道瞬间断裂，彻底告别“需要切两次”的 Bug！
        pkill -P $$ socat 2>/dev/null
        break
    fi
done
