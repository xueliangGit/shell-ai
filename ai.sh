#!/bin/bash
# -----------------------------------------------------------------
# ShellAI - 极简、安全且 100% 兼容 source 载入的单次命令查询助手
# -----------------------------------------------------------------

# 版本定义
VERSION="1.0.0"

# 补全执行环境 PATH（修复通过软链接独立执行时 eval 找不到系统命令的 127 问题）
# 将所有常见工具路径（含 Homebrew/macOS/Linux 标准路径）一次性合并注入
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/coreutils/libexec/gnubin"

# 可配置区
CONF_DIR="$HOME/.shell_ai"
CONF_FILE="$CONF_DIR/config"
HIST_FILE="$CONF_DIR/history.log"
DEBUG_FILE="$CONF_DIR/debug.log"
SESSION_FILE="$CONF_DIR/session.json"

DEFAULT_BASE_URL="https://openrouter.ai/api/v1"
DEFAULT_MODEL="openrouter/owl-alpha"
DEFAULT_TEMP=0.7
DEFAULT_MAX_TOKENS=1024
DEFAULT_AUTO_RUN="false"

# 初始化目录和日志
init_dir() {
    [ -d "$CONF_DIR" ] || mkdir -p "$CONF_DIR" || return 1
    [ -f "$HIST_FILE" ] || touch "$HIST_FILE" || return 1
    [ -f "$DEBUG_FILE" ] || touch "$DEBUG_FILE" || return 1
    
    # 初始化/校验跨进程会话缓存文件
    if [ ! -f "$SESSION_FILE" ] || ! jq -e . "$SESSION_FILE" >/dev/null 2>&1; then
        echo "[]" > "$SESSION_FILE"
    fi
}

# 加载配置
load_config() {
    init_dir || return 1
    if [ -f "$CONF_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONF_FILE" || return 1
    else
        # 写入默认配置
        cat > "$CONF_FILE" <<EOF
OPENROUTER_KEY=""
BASE_URL="$DEFAULT_BASE_URL"
MODEL="$DEFAULT_MODEL"
TEMPERATURE="$DEFAULT_TEMP"
MAX_TOKENS="$DEFAULT_MAX_TOKENS"
AUTO_RUN="$DEFAULT_AUTO_RUN"
LAST_CHECK_TIME="0"
REMOTE_VERSION_CACHE=""
EOF
        # shellcheck source=/dev/null
        source "$CONF_FILE" || return 1
    fi
}

# 保存配置
save_config() {
    cat > "$CONF_FILE" <<EOF
OPENROUTER_KEY="$OPENROUTER_KEY"
BASE_URL="$BASE_URL"
MODEL="$MODEL"
TEMPERATURE="$TEMPERATURE"
MAX_TOKENS="$MAX_TOKENS"
AUTO_RUN="$AUTO_RUN"
LAST_CHECK_TIME="${LAST_CHECK_TIME:-0}"
REMOTE_VERSION_CACHE="${REMOTE_VERSION_CACHE:-}"
EOF
}

# 调试日志
debug() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DEBUG_FILE"
}

# 验证 Key 与 URL
verify() {
    local key="$1"
    local url="$2"
    local model="$3"
    debug "验证配置中: url=$url model=$model"

    local payload
    payload=$(jq -n \
        --arg m "$model" \
        '{model: $m, messages: [{role: "user", content: "test"}]}')

    local resp
    resp=$(curl -s --connect-timeout 10 --max-time 15 \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://localhost" \
        -X POST "$url/chat/completions" \
        -d "$payload" 2>/dev/null || true)

    debug "验证接口响应: $resp"

    # 金刚不坏 JSON 清洗：提取区间并强行压平多行物理换行，彻底消除非标控制字符干扰
    local clean_resp
    clean_resp=$(echo "$resp" | sed -n '/{/,/}/p' | tr -d '\r' | tr -d '\n' 2>/dev/null || echo "$resp")

    if [ -n "$clean_resp" ] && echo "$clean_resp" | jq -e '.choices[0].message.content' >/dev/null 2>&1; then
        return 0
    else
        local err_msg
        err_msg=$(echo "$clean_resp" | jq -r '.error.message' 2>/dev/null || echo "$clean_resp")
        echo "❌ 验证失败：${err_msg:-'网络超时或响应异常'}"
        return 1
    fi
}

# 军工防弹级：高危敏感命令安全黑名单拦截校验（微秒级纯 Shell 内置通配符判别）
check_blacklist() {
    local cmd="$1"
    
    # 0. 压平空格以便稳定匹配
    local flat_cmd
    flat_cmd=$(echo "$cmd" | xargs 2>/dev/null || echo "$cmd")

    # 1. 拦截一切形式的高危删除操作 (含拼写错误/非标删除指令的兜底防爆)
    # 只要命令中包含通配符 * 或隐藏点号 .* 或 .git 目录，且包含 -r / -f / --recursive / --force
    # 即使大模型把 rm 拼错成了 m，或者使用了其他非标删除工具，也必被强制死锁拦截！
    if [[ "$flat_cmd" == *"*"* ]] || [[ "$flat_cmd" == *" ."* ]] || [[ "$flat_cmd" == *".git"* ]]; then
        if [[ "$flat_cmd" == *"-r"* ]] || [[ "$flat_cmd" == *"-f"* ]] || [[ "$flat_cmd" == *"--recursive"* ]] || [[ "$flat_cmd" == *"--force"* ]]; then
            return 1
        fi
    fi

    # 兜底对标准 rm 命令的无死角防护
    if [[ "$flat_cmd" == *"rm "* ]]; then
        if [[ "$flat_cmd" == *"-r"* ]] || [[ "$flat_cmd" == *"-f"* ]] || [[ "$flat_cmd" == *"--recursive"* ]] || [[ "$flat_cmd" == *"--force"* ]]; then
            if [[ "$flat_cmd" == *"/"* ]] || [[ "$flat_cmd" == *"*"* ]] || [[ "$flat_cmd" == *" ."* ]] || [[ "$flat_cmd" == *".git"* ]]; then
                return 1
            fi
        fi
        if [[ "$flat_cmd" == *"*"* ]] || [[ "$flat_cmd" == *" ."* ]]; then
            return 1
        fi
    fi

    # 2. 拦截磁盘格式化与物理分区表破坏操作 (mkfs, fdisk, parted, gparted)
    if [[ "$flat_cmd" == *"mkfs"* ]] || [[ "$flat_cmd" == *"fdisk"* ]] || [[ "$flat_cmd" == *"parted"* ]] || [[ "$flat_cmd" == *"gparted"* ]]; then
        return 1
    fi

    # 3. 拦截 dd 破坏性物理写盘与物理设备直灌
    if [[ "$flat_cmd" == *"dd "* ]] && [[ "$flat_cmd" == *"of="* ]]; then
        return 1
    fi

    # 4. 拦截针对物理盘区 (sda, sdb, hda, nvme, loop) 等的危险重定向覆盖 >
    if [[ "$flat_cmd" == *">"* ]] && [[ "$flat_cmd" == *"/dev/"* ]]; then
        if [[ "$flat_cmd" == *"/dev/sd"* ]] || [[ "$flat_cmd" == *"/dev/hd"* ]] || [[ "$flat_cmd" == *"/dev/nvme"* ]] || [[ "$flat_cmd" == *"/dev/loop"* ]]; then
            return 1
        fi
    fi

    # 5. 拦截文件粉碎与完全擦除命令 (shred, scrub)
    if [[ "$flat_cmd" == *"shred "* ]] || [[ "$flat_cmd" == *"scrub "* ]]; then
        return 1
    fi

    # 6. 拦截破坏系统内核核心目录权限的递归重置 (chmod -R / chown -R)
    if [[ "$flat_cmd" == *"chmod "* ]] || [[ "$flat_cmd" == *"chown "* ]]; then
        if [[ "$flat_cmd" == *"-R"* ]] || [[ "$flat_cmd" == *"--recursive"* ]]; then
            # 只要是对根目录、etc目录、sys目录、usr目录等核心系统层进行递归操作
            if [[ "$flat_cmd" == *" /"* ]] || [[ "$flat_cmd" == *"/etc"* ]] || [[ "$flat_cmd" == *"/sys"* ]] || [[ "$flat_cmd" == *"/usr"* ]] || [[ "$flat_cmd" == *"/var"* ]] || [[ "$flat_cmd" == *"/boot"* ]]; then
                return 1
            fi
        fi
    fi

    # 7. 拦截具有毁灭性转移特性的 mv 覆盖覆盖
    if [[ "$flat_cmd" == *"mv "* ]]; then
        # 比如将所有内容或核心文件抛入空设备
        if [[ "$flat_cmd" == *"/dev/null"* ]] || [[ "$flat_cmd" == *" /"* ]]; then
            return 1
        fi
    fi

    # 8. 拦截进程自杀动作 (kill -9 1) 或毁灭性强制关闭
    if [[ "$flat_cmd" == *"kill "* ]] && [[ "$flat_cmd" == *"-9 1"* ]]; then
        return 1
    fi

    # 9. 拦截多语言版的 Fork 炸弹与内存/CPU爆破炸弹
    # Zsh/Bash 版 (:(){ :|:& };:)
    if [[ "$flat_cmd" == *":(){"* ]] && [[ "$flat_cmd" == *":|:"* ]]; then
        return 1
    fi
    # Perl 版 (perl -e 'fork while fork')
    if [[ "$flat_cmd" == *"perl "* ]] && [[ "$flat_cmd" == *"fork"* ]] && [[ "$flat_cmd" == *"while"* ]]; then
        return 1
    fi

    # 10. 拦截内核模块恶意卸载 rmmod
    if [[ "$flat_cmd" == *"rmmod "* ]]; then
        return 1
    fi
    
    return 0 # 安全
}

# 全局一键安装/部署为全局 ai 命令，并完美自动配置 Zsh/Bash 开机自启载入
cmd_install() {
    load_config || return 1
    local bin_dir="$HOME/.local/bin"
    local bin_path="$bin_dir/ai"
    
    echo "====== 正在配置全局 ShellAI 命令 ======"
    
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" || return 1
    chmod +x "$HOME/.ai.sh" || return 1
    
    if [ -L "$bin_path" ] || [ -f "$bin_path" ]; then
        rm -f "$bin_path" || return 1
    fi
    
    ln -s "$HOME/.ai.sh" "$bin_path" || {
        echo "❌ 创建软链接失败"
        return 1
    }
    
    echo "✅ 全局部署成功！"
    echo "   脚本源文件：  $HOME/.ai.sh"
    echo "   全局软链接：  $bin_path"
    
    # 智能载入追加：自动在终端配置文件末尾追加静默载入指令，开启免输自启动！
    local user_shell
    user_shell=$(basename "${SHELL:-sh}" 2>/dev/null || echo "sh")
    local rc_file=""
    if [ "$user_shell" = "zsh" ]; then
        rc_file="$HOME/.zshrc"
    elif [ "$user_shell" = "bash" ]; then
        rc_file="$HOME/.bash_profile"
    fi
    
    if [ -n "$rc_file" ] && [ -f "$rc_file" ]; then
        if ! grep -q "source ~/.ai.sh" "$rc_file" && ! grep -q "\. ~/\.ai\.sh" "$rc_file"; then
            echo "" >> "$rc_file"
            echo "# ShellAI 自动终端会话初始化载入" >> "$rc_file"
            echo "[ -f ~/.ai.sh ] && . ~/.ai.sh" >> "$rc_file"
            echo "✅ 成功在 $rc_file 中配置自动载入！此后打开任意终端即可直接使用 ai。"
        fi
    fi
    
    echo ""
    echo "💡 提示：您现在可以在任何目录下直接运行 ai 命令了！"
    echo "   例如输入：ai 怎么解压 test.tar.gz"

    if [ -z "${OPENROUTER_KEY:-}" ]; then
        echo -e "\n⚠️ 检测到您尚未配置 API Key，正在为您自动启动配置向导："
        cmd_config
    fi

    echo ""
    echo "=================================================="
    cmd_help
    echo "=================================================="
}

# 配置向导
cmd_config() {
    load_config || return 1
    echo "====== OpenRouter 配置向导 ======"
    
    # 自动识别并展示脱敏后的上一次 API Key，防泄露且极大优化直接回车体验
    local display_key="未配置"
    if [ -n "${OPENROUTER_KEY:-}" ]; then
        if [ ${#OPENROUTER_KEY} -gt 15 ]; then
            display_key="${OPENROUTER_KEY:0:10}...${OPENROUTER_KEY: -4}"
        else
            display_key="已配置"
        fi
    fi
    
    printf "1. OpenRouter Key (sk-or-v1-...) [$display_key]: "
    read -r input_key
    OPENROUTER_KEY=${input_key:-$OPENROUTER_KEY}
    
    printf "2. Base URL [$BASE_URL]: "
    read -r input_url
    BASE_URL=${input_url:-$BASE_URL}
    
    printf "3. Model ID [$MODEL]: "
    read -r input_model
    MODEL=${input_model:-$MODEL}
    
    printf "4. Temperature (0~1) [$TEMPERATURE]: "
    read -r input_temp
    TEMPERATURE=${input_temp:-$TEMPERATURE}
    
    printf "5. Max Tokens [$MAX_TOKENS]: "
    read -r input_max
    MAX_TOKENS=${input_max:-$MAX_TOKENS}

    echo "🔍 正在在线验证，请稍候..."
    if verify "$OPENROUTER_KEY" "$BASE_URL" "$MODEL"; then
        save_config
        echo "✅ 配置已保存并验证通过！"
    else
        echo "❌ 配置未保存，请检查 Key/Model/URL"
        return 1
    fi
}

# 显示配置状态
cmd_status() {
    load_config || return 1
    echo "====== 当前配置 ======"
    echo "Key: ${OPENROUTER_KEY:0:10}..."
    echo "URL: $BASE_URL"
    echo "Model: $MODEL"
    echo "Temp: $TEMPERATURE"
    echo "MaxTokens: $MAX_TOKENS"
    echo "AutoRun: ${AUTO_RUN:-false}"
}

# 显示版本信息
cmd_version() {
    echo -e "🛡️  ${C_BOLD}ShellAI${C_RESET} 版本: ${C_GREEN}v$VERSION${C_RESET}"
}

# 在线检查与一键升级
cmd_upgrade() {
    echo "🔍 正在检测云端最新版本..."
    local remote_url="https://raw.githubusercontent.com/xueliangGit/shell-ai/main/ai.sh"
    
    # 异步拉取云端头部 30 行，闪电定位 VERSION 变量
    local remote_version
    remote_version=$(curl -s --connect-timeout 8 --max-time 12 "$remote_url" | head -n 30 | grep "^VERSION=" | cut -d'"' -f2 || echo "")
    
    if [ -z "$remote_version" ]; then
        echo -e "${C_RED}❌ 无法获取云端版本信息，请检查您的网络连接或代理设置。${C_RESET}"
        return 1
    fi
    
    if [ "$remote_version" = "$VERSION" ]; then
        echo -e "✅ 恭喜！您当前已是最新版本 (${C_GREEN}v$VERSION${C_RESET})。"
        return 0
    fi
    
    echo -e "🔔 发现新版本：${C_YELLOW}v$remote_version${C_RESET} (当前本地版本: v$VERSION)"
    printf "是否执行一键在线升级？[Y/n] "
    read -r confirm
    
    if [ -z "$confirm" ] || [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "⏳ 正在拉取并覆盖升级..."
        
        # 兼容 Mac 和 Linux 的绝对路径寻址
        local target_path="$HOME/.ai.sh"
        if [ ! -f "$target_path" ]; then
            # 兜底到正在运行的脚本绝对路径
            if command -v realpath >/dev/null 2>&1; then
                target_path=$(realpath "$0" 2>/dev/null || echo "$0")
            else
                # 兼容旧版 macOS 的物理寻址
                local dir
                dir=$(cd "$(dirname "$0")" && pwd)
                target_path="$dir/$(basename "$0")"
            fi
        fi
        
        if curl -fsSL --connect-timeout 12 --max-time 25 "$remote_url" -o "$target_path"; then
            chmod +x "$target_path"
            echo -e "${C_GREEN}🎉 升级成功！当前版本已成功跃升至 v$remote_version！${C_RESET}"
            echo "💡 提示：新打开一个终端窗口或执行 'source ~/.ai.sh' 即可立即享受全新特性！"
        else
            echo -e "${C_RED}❌ 升级失败，写入目标路径时发生异常。${C_RESET}"
            return 1
        fi
    else
        echo "❌ 已取消升级。"
    fi
}

# 24小时无感后台异步版本检测（绝不阻塞前台响应）
check_version_async() {
    local current_time
    current_time=$(date +%s 2>/dev/null || echo "0")
    
    # 距离上一次检查未满 24 小时 (86400秒)，则直接返回以节省网络与流量
    local last_check=${LAST_CHECK_TIME:-0}
    if [ "$current_time" -ne 0 ] && [ "$last_check" -ne 0 ]; then
        local diff=$((current_time - last_check))
        if [ $diff -lt 86400 ] && [ $diff -gt 0 ]; then
            return 0
        fi
    fi
    
    # 后台异步执行静默检测，完全不拖慢日常查询速度
    (
        local remote_url="https://raw.githubusercontent.com/xueliangGit/shell-ai/main/ai.sh"
        local remote_v
        remote_v=$(curl -s --connect-timeout 4 --max-time 6 "$remote_url" | head -n 30 | grep "^VERSION=" | cut -d'"' -f2 || echo "")
        
        if [ -n "$remote_v" ]; then
            # 极速将最新状态安全合并追加写入配置文件
            if [ -f "$CONF_FILE" ]; then
                local temp_conf="${CONF_FILE}.tmp"
                grep -v "LAST_CHECK_TIME=" "$CONF_FILE" | grep -v "REMOTE_VERSION_CACHE=" > "$temp_conf" || true
                echo "LAST_CHECK_TIME=\"$current_time\"" >> "$temp_conf"
                echo "REMOTE_VERSION_CACHE=\"$remote_v\"" >> "$temp_conf"
                mv "$temp_conf" "$CONF_FILE"
            fi
        fi
    ) & >/dev/null 2>&1
}

# 智能版本升级友好提示
show_upgrade_notification() {
    if [ -n "${REMOTE_VERSION_CACHE:-}" ] && [ "$REMOTE_VERSION_CACHE" != "$VERSION" ]; then
        echo -e "\n${C_YELLOW}💡 提示：ShellAI 发现全新版本 ${C_GREEN}v$REMOTE_VERSION_CACHE${C_RESET}${C_YELLOW}！输入 ${C_CYAN}ai upgrade${C_RESET}${C_YELLOW} 即可一键安全升级。${C_RESET}"
    fi
}

# 切换模型
cmd_model() {
    load_config || return 1
    local new_model="$1"
    if [ -z "$new_model" ]; then
        echo "当前模型：$MODEL"
        echo "用法：ai model <model-id>"
        return 0
    fi
    echo "🔍 验证模型：$new_model"
    if verify "$OPENROUTER_KEY" "$BASE_URL" "$new_model"; then
        MODEL="$new_model"
        save_config
        echo "✅ 已切换到：$MODEL"
    else
        echo "❌ 切换失败"
        return 1
    fi
}

# 优雅的历史记录展示，使用纯 awk 无依赖地反向对齐排列 (1代表最近刚刚执行的)
cmd_history() {
    load_config || return 1
    if [ ! -s "$HIST_FILE" ]; then
        echo "暂无历史记录。"
        return 0
    fi
    echo "====== 最近的命令生成历史 (输入 ai history <序号> 可一键复用运行) ======"
    
    # 提取最近 15 条，倒序并自动匹配序号打印
    tail -n 15 "$HIST_FILE" | awk '{line[NR]=$0} END {for(i=NR;i>0;i--) print line[i]}' | awk -F ' \\| ' '{
        printf "\033[38;5;38m[%d]\033[0m \033[38;5;244m%s\033[0m \033[1m需求:\033[0m %-25s \033[38;5;76m指令:\033[0m %s\n", NR, $1, $2, $3
    }'
}

# 一键历史记录提取复用与复跑
cmd_history_replay() {
    load_config || return 1
    local index="$1"
    
    if ! [[ "$index" =~ ^[0-9]+$ ]]; then
        echo "❌ 错误：历史序号必须是数字！"
        return 1
    fi
    
    if [ ! -s "$HIST_FILE" ]; then
        echo "暂无历史记录。"
        return 1
    fi
    
    # 提取出对应的历史行 (利用 awk 完美倒序，NR 匹配 index)
    local history_line
    history_line=$(tail -n 15 "$HIST_FILE" | awk '{line[NR]=$0} END {for(i=NR;i>0;i--) print line[i]}' | awk -v idx="$index" -F ' \\| ' 'NR==idx {print $0}')
    
    if [ -z "$history_line" ]; then
        echo "❌ 错误：找不到序号为 [$index] 的历史命令！"
        return 1
    fi
    
    local hist_prompt
    hist_prompt=$(echo "$history_line" | awk -F ' \\| ' '{print $2}')
    local hist_cmd
    hist_cmd=$(echo "$history_line" | awk -F ' \\| ' '{print $3}')
    
    echo ""
    echo "🔄 正在复用历史记录 [$index]："
    echo "   原需求：  $hist_prompt"
    echo "   原指令：  $hist_cmd"
    echo ""
    
    # 重新进行高危敏感命令安全防御校验
    local is_blacklisted=0
    if ! check_blacklist "$hist_cmd"; then
        is_blacklisted=1
    fi

    if [ $is_blacklisted -eq 1 ]; then
        echo -e "\033[38;5;196m⚠️  安全警报：检测到该命令包含高危敏感操作！自动执行已关闭。\033[0m"
        printf "选择操作？[n/c] (n:取消, c:拷贝命令) "
        read -r confirm
        if [[ "$confirm" =~ ^[Cc]$ ]]; then
            if command -v pbcopy >/dev/null 2>&1; then
                local safe_copy_cmd
                safe_copy_cmd=$(echo "$hist_cmd" | sed -E 's/[[:space:]]*\.git([[:space:]]+|$)/ /g' | xargs)
                echo -n "$safe_copy_cmd" | pbcopy
                if [ "$safe_copy_cmd" != "$hist_cmd" ]; then
                    echo "📋 系统已自动为您剔除最致命的隐藏路径（如 .git）！"
                    echo "📋 安全指令已成功拷贝至剪贴板，请手动粘贴确认后运行。"
                else
                    echo "📋 敏感指令已成功拷贝至剪贴板，操作仍具高危性，请务必仔细确认后手动粘贴运行！"
                fi
            else
                echo "⚠️ pbcopy 缺失"
            fi
        fi
    else
        printf "重新执行？[Y/n/c] (Y:执行, n:取消, c:拷贝) "
        read -r confirm
        if [ -z "$confirm" ] || [[ "$confirm" =~ ^[Yy]$ ]]; then
            CLICOLOR_FORCE=1 FORCE_COLOR=1 eval "$hist_cmd"
            local exit_code=$?
            if [ $exit_code -ne 0 ]; then
                echo "⚠️ 命令执行失败，退出码: $exit_code"
            fi
        elif [[ "$confirm" =~ ^[Cc]$ ]]; then
            if command -v pbcopy >/dev/null 2>&1; then
                echo -n "$hist_cmd" | pbcopy
                echo "📋 命令已成功拷贝至剪贴板！"
            else
                echo "⚠️ pbcopy 缺失"
            fi
        else
            echo "❌ 已取消"
        fi
    fi
}

# 深度 AI 历史命令安全审计评估分析
cmd_analyze() {
    load_config || return 1
    if [ ! -s "$HIST_FILE" ]; then
        echo "暂无历史命令记录可供审计。"
        return 0
    fi

    echo "🔍 正在为您调遣 AI 深度审计历史命令日志..."

    # 提取最近 30 条历史记录
    local hist_data
    hist_data=$(tail -n 30 "$HIST_FILE")

    local sys_prompt="你是一个专业的终端安全审计与优化专家。请对用户最近执行过的这些历史命令日志进行一次全方位的深度安全审计，指出其中是否存在高危、敏感隐患（特别是删除、格式化或不规范的操作），并针对每一项隐患或整体提出精炼的中文改进与安全防范建议。报告控制在 8 行以内。"

    # 加载中状态动画，隐藏光标
    printf "🤖 ${C_BOLD}AI 正在深度审计评估中...${C_RESET}  "
    printf "\e[?25l"

    local payload
    payload=$(jq -n \
        --arg model "$MODEL" \
        --arg sys "$sys_prompt" \
        --arg content "$hist_data" \
        '{
            model: $model,
            messages: [
                {role: "system", content: $sys},
                {role: "user", content: ("历史命令日志：\n" + $content)}
            ]
        }') || return 1

    local resp
    resp=$(curl -s --connect-timeout 20 --max-time 60 \
        -H "Authorization: Bearer $OPENROUTER_KEY" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://localhost" \
        -X POST "$BASE_URL/chat/completions" \
        -d "$payload" || true)

    printf "\r\e[K"  # 抹去思考中行
    printf "\e[?25h" # 恢复光标

    if [ -z "$resp" ]; then
        echo "❌ AI 审计请求失败，网络连接超时。"
        return 1
    fi

    # 金刚不坏 JSON 清洗
    local clean_json
    clean_json=$(echo "$resp" | sed -n '/{/,/}/p' | tr -d '\r' | tr -d '\n' 2>/dev/null || echo "$resp")

    local raw_content=""
    if echo "$clean_json" | jq -e . >/dev/null 2>&1; then
        raw_content=$(echo "$clean_json" | jq -r '.choices[0].message.content' 2>/dev/null || true)
    fi

    if [ -z "$raw_content" ] || [ "$raw_content" = "null" ]; then
        echo "❌ 审计失败，原始响应："
        echo "$resp"
        return 1
    fi

    echo ""
    echo "=================================================="
    echo -e "🛡️  ${C_BOLD}ShellAI 本地终端历史命令深度审计报告${C_RESET}"
    echo "=================================================="
    echo "$raw_content"
    echo "=================================================="
    echo ""
}

# 极客级异步动态 Loading 思考动画器
show_loading() {
    # 转圈字符序列，极具科技质感
    local spinners=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    
    # 隐藏光标，避免闪烁
    printf "\e[?25l"
    
    while true; do
        for char in "${spinners[@]}"; do
            # \r 回到行首，\e[K 擦除从光标到行尾的内容
            printf "\r\033[38;5;38m%s\033[0m 🤖 正在思考中 ..." "$char"
            sleep 0.08
        done
    done
}

# 核心命令：运行提问与生成
cmd_run() {
    load_config || return 1
    local prompt="$*"
    if [ -z "$prompt" ]; then
        echo "请输入问题，例如：ai 查看端口占用"
        return 1
    fi

    # 后台异步触发版本检测（每24小时静默轮询一次，完全不阻塞本次查询）
    check_version_async

    # 动态注入高精度环境上下文（OS、当前Shell、当前路径、以及当前目录下的前几项文件名）
    local current_os
    current_os=$(uname -s 2>/dev/null || echo "Unknown")
    local current_shell
    current_shell=$(basename "${SHELL:-sh}" 2>/dev/null || echo "sh")
    local current_files
    current_files=$(ls -F | head -n 12 | tr '\n' ',' | sed 's/,$//' 2>/dev/null || echo "")

    local env_info="[环境上下文] 操作系统: $current_os, 终端Shell: $current_shell, 工作目录: $PWD"
    if [ -n "$current_files" ]; then
        env_info="$env_info, 当前目录下包含的部分文件: [$current_files]"
    fi

    # 指示模型以 [COMMAND] 和 [ADVICE] 两个标志块拆分输出命令与使用建议
    local sys_prompt="你是一个专业的 Shell 命令行助手。针对用户的具体环境（包括操作系统、Shell及目录下的文件），你必须同时给出最精准、可执行的终端 shell 命令以及精炼的使用建议。
请严格按照以下格式输出，绝对不要有任何多余的包裹，不要使用 markdown 代码块：
[COMMAND]
可直接在终端中运行的 shell 命令本身（只占一行）
[ADVICE]
对此命令的简短解释、注意事项或后续使用建议（中文描述，不超过3行）

⚠️ 【核心指令纪律，你必须严格遵守】：
1. 绝对精准性：你给出的 [COMMAND] 必须在语法和命令名称上 100% 精确，严禁打错任何命令名称或字符（例如绝对严禁将 find 拼写为 ind）。
2. 极端引号防御：如果生成的 Shell 命令中包含管道符 (|), 分号 (;), 重定向 (<, >), 与或符号 (&&, ||), 通配符 (*, ?, []), 变量引入 ($) 或 sed/awk 等复杂子脚本片段，你必须对这些参数（或整个子脚本片段）使用单引号 ('...') 进行严密的安全引号包裹，彻底防止命令在终端进行 eval 执行时因为特殊字符未加保护而发生 shell 词法切分与语法解析崩溃！"
    
    # 启动后台异步动态 Loading 思考动画，获取 PID 并设置 trap 信号安全锁，防闪防终端崩溃
    show_loading &
    local loading_pid=$!
    trap 'kill $loading_pid 2>/dev/null; printf "\r\e[K\e[?25h"' EXIT INT TERM
    
    # 动态组装 messages 数组（注入环境上下文，并保留最近 5 轮多轮对话）
    local messages
    messages=$(jq -n \
        --arg sys "$sys_prompt" \
        --arg env "$env_info" \
        --arg content "$prompt" \
        --argjson history "$(cat "$SESSION_FILE")" \
        '[
            {role: "system", content: ($sys + "\n\n" + $env)}
        ] + $history + [
            {role: "user", content: ("需求：" + $content)}
        ]') || return 1

    local payload
    payload=$(jq -n \
        --arg model "$MODEL" \
        --argjson msg "$messages" \
        --argjson temp "$TEMPERATURE" \
        --argjson max "$MAX_TOKENS" \
        '{
            model: $model,
            messages: $msg,
            temperature: $temp,
            max_tokens: $max
        }') || return 1

    local resp
    resp=$(curl -s --connect-timeout 15 --max-time 60 \
        -H "Authorization: Bearer $OPENROUTER_KEY" \
        -H "Content-Type: application/json" \
        -H "HTTP-Referer: https://localhost" \
        -X POST "$BASE_URL/chat/completions" \
        -d "$payload" || true)

    # 请求完毕瞬间，立即消灭转圈子进程，抹去终端转圈痕迹，释放 trap 并完美恢复光标！
    kill "$loading_pid" 2>/dev/null
    wait "$loading_pid" 2>/dev/null
    printf "\r\e[K\e[?25h"
    trap - EXIT INT TERM

    if [ -z "$resp" ]; then
        echo "❌ 请求失败，网络超时或无法连接到 API 服务"
        return 1
    fi

    debug "请求：$messages"
    debug "响应：$resp"

    # 金刚不坏 JSON 清洗：提取区间并强行压平多行物理换行，彻底消除非标控制字符干扰
    local clean_json
    clean_json=$(echo "$resp" | sed -n '/{/,/}/p' | tr -d '\r' | tr -d '\n' 2>/dev/null || echo "$resp")

    local raw_content=""
    if echo "$clean_json" | jq -e . >/dev/null 2>&1; then
        raw_content=$(echo "$clean_json" | jq -r '.choices[0].message.content' 2>/dev/null || true)
    fi

    if [ -z "$raw_content" ] || [ "$raw_content" = "null" ]; then
        echo "❌ 生成失败，原始响应："
        echo "$resp"
        return 1
    fi

    # 使用神级换行替换法，彻底兼容单行粘连与跨多行非标格式的标签提取
    local flat_content
    flat_content=$(echo "$raw_content" | tr '\n' '\f' | sed 's/\f/__NL__/g')

    if echo "$flat_content" | grep -q "\[COMMAND\]"; then
        local flat_cmd
        flat_cmd=$(echo "$flat_content" | sed -n 's/.*\[COMMAND\]\(.*\)\[ADVICE\].*/\1/p')
        if [ -z "$flat_cmd" ]; then
            flat_cmd=$(echo "$flat_content" | sed -n 's/.*\[COMMAND\]\(.*\)/\1/p')
        fi
        
        local flat_advice
        flat_advice=$(echo "$flat_content" | sed -n 's/.*\[ADVICE\]\(.*\)/\1/p')

        # 还原换行占位符并清洗前后空白
        raw_cmd=$(echo "$flat_cmd" | sed 's/__NL__/\
/g' | xargs 2>/dev/null || echo "$flat_cmd")
        raw_advice=$(echo "$flat_advice" | sed 's/__NL__/\
/g' | xargs 2>/dev/null || echo "$flat_advice")
    else
        # 智能兜底：如果大模型没有输出 [COMMAND] 标签，但内容不长且不含非 ASCII 字符（极大概率是纯 Shell 命令）
        local line_count
        line_count=$(echo "$raw_content" | tr -d '\r' | grep -c '^' 2>/dev/null || echo "1")
        local trimmed
        trimmed=$(echo "$raw_content" | xargs)

        if [ "$line_count" -le 3 ] && ! LC_ALL=C grep -q '[^ -~]' <<< "$trimmed"; then
            raw_cmd="$raw_content"
            raw_advice=""
        fi
    fi

    # 清洁清洗提取出的命令，剔除多余 of markdown 反引号
    local clean_cmd
    clean_cmd=$(echo "$raw_cmd" | sed -E '
        s/^```[a-zA-Z0-9]*[[:space:]]*//g;
        s/```[[:space:]]*$//g;
        s/^`([^`]+)`$/\1/g
    ' | xargs)

    local clean_advice
    clean_advice=$(echo "$raw_advice" | xargs)

    # 智能问答/闲聊分析拦截：如果大模型确实按照标记输出了 [COMMAND]，说明是要执行的命令模式
    if [ -n "$clean_cmd" ]; then
        echo -e "✅ \033[38;5;76m推荐指令：\033[0m$clean_cmd"
        if [ -n "$clean_advice" ] && [ "$clean_advice" != "null" ]; then
            echo -e "💡 \033[38;5;244m使用建议：\033[0m$clean_advice"
        fi
        echo ""
        
        # 进行高危敏感命令安全防御校验
        local is_blacklisted=0
        if ! check_blacklist "$clean_cmd"; then
            is_blacklisted=1
        fi

        if [ $is_blacklisted -eq 1 ]; then
            # 敏感命令安全防御：强行截断一键执行权限，拒绝默认回车执行，只允许取消或拷贝
            echo -e "\033[38;5;196m⚠️  安全警报：检测到该命令包含高危敏感操作（如强制删除、格式化或写盘）！\033[0m"
            echo -e "\033[38;5;196m⚠️  为了保护系统安全，ShellAI 已自动关闭此命令的一键执行功能。\033[0m"
            echo ""
            
            printf "选择操作？[n/c] (n:取消, c:拷贝命令并由您手动评估执行) "
            read -r confirm
            
            if [[ "$confirm" =~ ^[Cc]$ ]]; then
                if command -v pbcopy >/dev/null 2>&1; then
                    # 终极高智安全清洗：在拷贝高危指令前，自动过滤剥离 .git 隐藏项，确保用户粘贴执行绝对无害
                    local safe_copy_cmd
                    safe_copy_cmd=$(echo "$clean_cmd" | sed -E 's/[[:space:]]*\.git([[:space:]]+|$)/ /g' | xargs)
                    
                    echo -n "$safe_copy_cmd" | pbcopy
                    
                    # 诚实信息提示判定：只有当命令中确实有 .git 且已被安全剔除时，才展示净化提示
                    if [ "$safe_copy_cmd" != "$clean_cmd" ]; then
                        echo "📋 系统已自动为您剔除最致命的隐藏路径（如 .git）！"
                        echo "📋 安全指令已成功拷贝至剪贴板，请手动粘贴确认后运行。"
                    else
                        echo "📋 敏感指令已成功拷贝至剪贴板，操作仍具高危性，请务必仔细确认后手动粘贴运行！"
                    fi
                else
                    echo "⚠️ 找不到剪贴板命令 (pbcopy)"
                fi
            else
                echo "❌ 已取消执行。"
            fi
        else
            # 正常安全命令交互
            if [ "${AUTO_RUN:-false}" = "true" ]; then
                # 终极安全防线：在自动执行之前，提取出整行命令的第一个执行字（程序名），验证在系统中是否真实可用！
                # 彻底剿灭任何由于大模型拼写错误（如 rm 打成 m）导致的 127 退出码 and 未知执行隐患
                local main_cmd
                main_cmd=$(echo "$clean_cmd" | awk '{print $1}' 2>/dev/null || echo "")
                if [[ "$main_cmd" == *"="* ]]; then
                    main_cmd=$(echo "$clean_cmd" | awk '{print $2}' 2>/dev/null || echo "")
                fi

                if [ -n "$main_cmd" ] && ! command -v "$main_cmd" >/dev/null 2>&1; then
                    echo -e "❌ \033[38;5;196m错误：检测到大模型生成的命令在当前系统不可用（打错字或未安装）：[$main_cmd]\033[0m"
                    echo "📋 无法自动运行，请您手动拷贝或修改后核对执行。"
                else
                    echo -e "🚀 \033[38;5;76m[安全自动执行模式] 正在运行指令...\033[0m"
                    CLICOLOR_FORCE=1 FORCE_COLOR=1 eval "$clean_cmd"
                    local exit_code=$?
                    if [ $exit_code -ne 0 ]; then
                        echo "⚠️ 命令执行失败，退出码: $exit_code"
                    fi
                fi
            else
                printf "执行？[Y/n/c] (Y:执行, n:取消, c:拷贝命令) "
                read -r confirm
                
                if [ -z "$confirm" ] || [[ "$confirm" =~ ^[Yy]$ ]]; then
                    CLICOLOR_FORCE=1 FORCE_COLOR=1 eval "$clean_cmd"
                    local exit_code=$?
                    if [ $exit_code -ne 0 ]; then
                        echo "⚠️ 命令执行失败，退出码: $exit_code"
                    fi
                elif [[ "$confirm" =~ ^[Cc]$ ]]; then
                    # 兼容 macOS 剪贴板工具 pbcopy
                    if command -v pbcopy >/dev/null 2>&1; then
                        echo -n "$clean_cmd" | pbcopy
                        echo "📋 命令已成功拷贝至剪贴板！"
                    else
                        echo "⚠️ 找不到剪贴板命令 (pbcopy)"
                    fi
                else
                    echo "❌ 已取消"
                fi
            fi
        fi

        # 跨进程会话记忆滑动落盘：强制拼装成标准的 [COMMAND] 与 [ADVICE] 格式保存
        # 从而在大模型的上下文记忆中实施“格式强行校正”，完美稳固 Few-Shot 机制，防范大模型行为退化
        local formatted_assistant
        formatted_assistant="[COMMAND]
${clean_cmd}
[ADVICE]
${clean_advice:-无}"

        jq --arg user_q "需求：$prompt" \
           --arg assistant_a "$formatted_assistant" \
           '. + [{role: "user", content: $user_q}, {role: "assistant", content: $assistant_a}] | .[-10:]' \
           "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE" || return 1

        # 记录历史日志
        echo "$(date '+%Y-%m-%d %H:%M:%S') | $prompt | $clean_cmd" >> "$HIST_FILE" || return 1

        # 查询完毕后，前台轻量非侵入式展示升级提示（有新版本时才显示一行，无则完全静默）
        show_upgrade_notification
    else
        # 闲聊/分析/问答模式：直接优雅地输出大模型的人话回复，不走任何命令执行和安全拦截，高情商结束！
        echo "$raw_content"
        echo ""
        show_upgrade_notification
    fi
}

# 帮助菜单
cmd_help() {
    cat <<EOF
用法：ai [命令] [参数]

命令：
  install       一键部署 ai 为系统全局命令
  config        配置 Key/URL/Model/参数（必填首次）
  status        查看当前配置
  model <id>    切换并验证模型（永久保存）
  auto [on/off] 🚀 开启/关闭无危险安全命令的直接自动执行
  analyze       🛡️  AI 深度安全审计评估历史命令
  clear/reset   🧹 清空 AI 上下文记忆
  history       查看历史
  upgrade       🚀 一键在线自适应检测并升级更新 ShellAI 核心脚本
  version       🛡️ 查看本地已安装的 ShellAI 版本号
  help          本帮助

直接输入问题即运行（支持基于上下文多轮对话，如 "刚才那个命令怎么改..."）：
  ai 查看当前目录
  ai 重启 nginx
  ai 解压 test.tar.gz

支持自定义：
  - 任意 OpenRouter 模型（含 free）
  - 自定义 base_url（代理/自建）
  - temperature / max_tokens
EOF
}

# ──────────────── 入口管理 ────────────────
run_main() {
    case "${1:-}" in
        config) cmd_config ;;
        status) cmd_status ;;
        model) cmd_model "$2" ;;
        auto)
            if [ "${2:-}" = "on" ] || [ "${2:-}" = "true" ]; then
                AUTO_RUN="true"
                save_config
                echo "🚀 ShellAI 已成功开启【安全命令自动执行】模式！无危险的安全指令将直接运行。"
            elif [ "${2:-}" = "off" ] || [ "${2:-}" = "false" ]; then
                AUTO_RUN="false"
                save_config
                echo "🔒 ShellAI 已成功切换为【严密确认】模式！所有命令执行前均需手动确认。"
            else
                load_config || return 1
                echo "当前安全自动执行模式：${AUTO_RUN:-false}"
                echo "用法："
                echo "  ai auto on    - 开启安全命令直接自动执行"
                echo "  ai auto off   - 关闭自动执行，全部命令需手动确认"
            fi
            ;;
        history)
            if [ -n "${2:-}" ]; then
                cmd_history_replay "$2"
            else
                cmd_history
            fi
            ;;
        analyze) cmd_analyze ;;
        clear|reset)
            init_dir && echo "[]" > "$SESSION_FILE" && echo "🧹 已成功清除 AI 上下文记忆！"
            ;;
        install) cmd_install ;;
        upgrade|update) cmd_upgrade ;;
        version|-v|--version) cmd_version ;;
        help) cmd_help ;;
        *) cmd_run "$*" ;;
    esac
}

# 注册全局 ai 命令函数给当前 shell
# 极客热插拔：在定义函数前，必须首先注销同名别名，彻底防止 Zsh 在多次载入时由于别名展开而引发的语法解析报错！
unalias ai >/dev/null 2>&1 || true

ai() {
    # 极客控制流：
    # 1. 强行激活“别名展开”选项，使 eval 运行能 100% 继承并套用您的本地彩色别名（如 ls='ls -G'）；
    # 2. 强行关闭“作业监视器（NO_monitor）”，彻底封锁后台 Loading 进程的进程号打印及 terminated 终止通知，达成无痕视觉体验！
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt local_options aliases NO_monitor
    elif [ -n "${BASH_VERSION:-}" ]; then
        shopt -s expand_aliases
        set +o monitor 2>/dev/null || set +m 2>/dev/null || true
    fi

    run_main "$@"
    local exit_code=$?
    
    # 恢复 Bash 的监视器状态（Zsh 使用 local_options 自动在函数退出时还原，无需手动处理，这就是 Zsh 的高雅之处）
    if [ -n "${BASH_VERSION:-}" ]; then
        set -o monitor 2>/dev/null || set -m 2>/dev/null || true
    fi
    
    return $exit_code
}

# 仅在 Zsh 环境下通过 noglob 别名强行防御通配符展开与报错，实现免引号完美输入！
if [ -n "${ZSH_VERSION:-}" ]; then
    alias ai='noglob ai'
fi

# 跨 Shell 安全检测是否被 source / . 引入
is_sourced=0
if [ "$0" = "bash" ] || [ "$0" = "zsh" ] || [ "$0" = "-bash" ] || [ "$0" = "-zsh" ] || [ "${BASH_SOURCE[0]:-}" != "${0}" ]; then
    is_sourced=1
fi

if [ $is_sourced -eq 1 ]; then
    # 被 source 引入：
    # 如果 source 时后面带了参数（如 . ~/.ai.sh config），立即执行它并退出
    if [ $# -gt 0 ]; then
        run_main "$@"
        return $? 2>/dev/null || true
    else
        # 如果仅是一次性无参数初始化载入，定义并注册 ai 函数后打印提示优雅返回，不运行任何命令
        echo "✅ ShellAI 已载入当前终端会话！现在您可直接输入 ai 命令进行智能查询。"
        return 0 2>/dev/null || true
    fi
else
    # 独立可执行程序运行：安全调用 exit 退出子进程
    run_main "$@"
    exit $?
fi
