#!/bin/bash

STATE_FILE="/tmp/hypr_fake_overview_state"
SOCKET="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

# ==========================================
# 1. 再次按键时取消 (Toggle 逻辑)
# ==========================================
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    
    # 【修复点 1】直接恢复全局布局，而不是写入工作区规则
    hyprctl keyword general:layout "$SAVED_LAYOUT" > /dev/null
    
    rm -f "$STATE_FILE"
    
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

echo "SAVED_WS=$current_ws" > "$STATE_FILE"
echo "SAVED_LAYOUT=$current_layout" >> "$STATE_FILE"
echo "OLD_SCRIPT_PID=$$" >> "$STATE_FILE"

# 【修复点 2】直接修改全局布局为 dwindle
hyprctl keyword general:layout dwindle > /dev/null

sleep 0.1

# ==========================================
# 3. 实时监听事件 (解决需要切换两次的 Bug)
# ==========================================
socat -U - UNIX-CONNECT:"$SOCKET" 2>/dev/null | while read -r line; do
    if [[ "$line" =~ ^(activewindowv2>>|focusedmon>>) ]]; then
        
        if [ -f "$STATE_FILE" ]; then
            # 【修复点 3】监听触发时，恢复全局布局
            hyprctl keyword general:layout "$current_layout" > /dev/null
            rm -f "$STATE_FILE"
        fi
        
        pkill -P $$ socat 2>/dev/null
        break
    fi
done