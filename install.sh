#!/bin/bash

# Colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'
white='\033[0;37m'
rest='\033[0m'

# Check and install ONLY essential packages
install_packages() {
    local packages=(wget curl unzip jq)
    local missing_packages=()
    
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo -e "${cyan}Installing missing packages: ${missing_packages[*]}${rest}"
        if [ -n "$(command -v apt)" ]; then
            sudo apt update -y && sudo apt install "${missing_packages[@]}" -y
        elif [ -n "$(command -v dnf)" ]; then
            sudo dnf install "${missing_packages[@]}" -y
        elif [ -n "$(command -v yum)" ]; then
            sudo yum install "${missing_packages[@]}" -y
        else
            echo -e "${red}Unsupported package manager.${rest}"
            exit 1
        fi
    else
        echo -e "${green}All required packages are already installed.${rest}"
    fi
}

install_packages

# Download and install Xray (Smart Check for Kali WSL)
install_xray() {
    if command -v xray &> /dev/null; then
        local xray_loc=$(command -v xray)
        local installed_version=$($xray_loc -version 2>/dev/null | grep -oE 'Xray [^ ]+' | awk '{print $2}')
        echo -e "${green}Local Xray found at $xray_loc (v$installed_version). Skipping download.${rest}"
        return
    fi

    latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name | sed 's/^v//')
    echo -e "${yellow}Xray not found. Downloading v$latest_version...${rest}"
    
    arch=$(uname -m)
    file_name="Xray-linux-64.zip"
    [ "$arch" == "aarch64" ] && file_name="Xray-linux-arm64-v8a.zip"
    
    url="https://github.com/XTLS/Xray-core/releases/download/v$latest_version/$file_name"
    wget -q --show-progress "$url" -O "$file_name" || { echo -e "${red}Download failed.${rest}"; exit 1; }
    unzip -oq "$file_name"
    sudo mv xray /usr/local/bin/
    sudo chmod +x /usr/local/bin/xray
    rm -f README.md LICENSE "$file_name"
    echo -e "${green}Xray installed successfully.${rest}"
}

install_xray

# Fragment Scanner
fragment_scanner() {
    # Dynamically find Xray path (Fix for Kali/WSL)
    XRAY_PATH="$(command -v xray)"
    CONFIG_PATH="config.json"
    LOG_FILE="pings.txt"
    XRAY_LOG_FILE="xraylogs.txt"

    if [ ! -f "$XRAY_PATH" ] && [ ! -x "$XRAY_PATH" ]; then
        echo -e "${red}Error: Xray executable not found.${rest}"
        return
    fi

    if [ ! -f "$CONFIG_PATH" ]; then
        echo -e "${red}Error: config.json not found. Please create a config first (Option 1).${rest}"
        return
    fi

    > "$LOG_FILE"
    > "$XRAY_LOG_FILE"

    echo -en "${green}Enter number of instances (default 15): ${rest}"
    read -r InstancesInput
    echo -en "${green}Enter timeout per ping in seconds (default 8): ${rest}"
    read -r TimeoutSecInput
    echo -en "${green}Enter HTTP Proxy Port (default 10809): ${rest}"
    read -r HTTP_PROXY_PORTInput
    echo -en "${green}Enter requests per instance (default 4): ${rest}"
    read -r PingCountInput

    Instances=${InstancesInput:-15}
    TimeoutSec=${TimeoutSecInput:-8}
    HTTP_PROXY_PORT=${HTTP_PROXY_PORTInput:-10809}
    PingCount=${PingCountInput:-4}

    HTTP_PROXY_SERVER="127.0.0.1"

    packetsOptions=("tlshello" "1-1" "1-2" "1-3" "2-3")
    lengthOptions=("1-1" "1-2" "1-3" "2-5" "1-5" "5-10" "10-20" "20-50")
    intervalOptions=("1-1" "1-2" "3-5" "5-10" "10-20" "20-50" "50-100")

    declare -a topThree
    declare -A usedCombinations

    get_random_value() {
        local options=("$@")
        echo "${options[RANDOM % ${#options[@]}]}"
    }

    get_unique_combination() {
        local combination packets length interval
        while true; do
            packets=$(get_random_value "${packetsOptions[@]}")
            length=$(get_random_value "${lengthOptions[@]}")
            interval=$(get_random_value "${intervalOptions[@]}")
            combination="$packets,$length,$interval"

            if [[ -z "${usedCombinations[$combination]}" ]]; then
                usedCombinations["$combination"]=1
                echo "$packets $length $interval"
                break
            fi
        done
    }

    modify_config() {
        local packets=$1 length=$2 interval=$3
        jq --arg packets "$packets" --arg length "$length" --arg interval "$interval" \
            '(.outbounds[] | select(.tag == "fragment") | .settings.fragment) |= {packets: $packets, length: $length, interval: $interval}' \
            "$CONFIG_PATH" > config.tmp && mv config.tmp "$CONFIG_PATH"
    }

    stop_xray_process() {
        pkill -f "xray run" 2>/dev/null
        sleep 0.5
        local pids=$(pgrep -f xray)
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    }

    # 100% Internal Bash Port Checker
    wait_for_port() {
        local port=$1 timeout=8 start=$SECONDS
        while ! (echo > /dev/tcp/127.0.0.1/$port) 2>/dev/null; do
            if (( SECONDS - start >= timeout )); then return 1; fi
            sleep 0.2
        done
        return 0
    }

    send_http_request() {
        local pingCount=$1 url="http://cp.cloudflare.com"
        local totalTime=0 validPings=0

        for ((i=1; i<=pingCount; i++)); do
            local time_sec=$(curl -w "%{time_total}" -o /dev/null -s --max-time "$TimeoutSec" -x "$HTTP_PROXY_SERVER:$HTTP_PROXY_PORT" "$url")
            
            if [ -n "$time_sec" ] && awk "BEGIN{exit !($time_sec > 0)}"; then
                local time_ms=$(awk "BEGIN {printf \"%.0f\", $time_sec * 1000}")
                totalTime=$((totalTime + time_ms))
                validPings=$((validPings + 1))
            fi
            sleep 0.5
        done

        if [ "$validPings" -gt 0 ]; then
            echo $((totalTime / validPings))
        else
            echo 0
        fi
    }

    echo -e "${yellow}+--------------+-----------------+---------------+-----------------+---------------+${rest}"
    echo -e "${cyan}|   Instance   |     Packets     |     Length    |     Interval    | Average Ping  |${rest}"
    echo -e "${yellow}+--------------+-----------------+---------------+-----------------+---------------+${cyan}"

    for ((i=0; i<Instances; i++)); do
        read packets length interval <<< "$(get_unique_combination)"
        modify_config "$packets" "$length" "$interval"
        stop_xray_process
        
        "$XRAY_PATH" run -c "$CONFIG_PATH" &> "$XRAY_LOG_FILE" &
        
        if ! wait_for_port "$HTTP_PROXY_PORT"; then
            printf "|      %-4s    |       %-8s  |      %-7s  |      %-7s    |      FAIL     |\n" "$((i + 1))" "$packets" "$length" "$interval"
            continue
        fi

        averagePing=$(send_http_request "$PingCount")
        topThree+=("$((i + 1)),$packets,$length,$interval,$averagePing")

        if [ "$averagePing" -gt 0 ]; then
            printf "|      %-4s    |       %-8s  |      %-7s  |      %-7s    |    %-6s ms  |\n" "$((i + 1))" "$packets" "$length" "$interval" "$averagePing"
        else
            printf "|      %-4s    |       %-8s  |      %-7s  |      %-7s    |      FAIL     |\n" "$((i + 1))" "$packets" "$length" "$interval"
        fi
    done

    echo -e "${yellow}+--------------+-----------------+---------------+-----------------+---------------+${rest}"

    validResults=()
    for result in "${topThree[@]}"; do
        IFS=',' read -r -a arr <<< "$result"
        [ "${arr[4]}" -gt 0 ] && validResults+=("$result")
    done

    if [ ${#validResults[@]} -gt 0 ]; then
        IFS=$'\n' sortedTopThree=($(sort -t, -k5 -n <<<"${validResults[*]}"))
        unset IFS
        echo ""
        echo -e "${green}Top 3 Best Fragment Configurations:${rest}"
        echo -e "${blue}******************************************${rest}"
        for result in "${sortedTopThree[@]:0:3}"; do
            IFS=',' read -r -a arr <<< "$result"
            echo -e "${purple}Packets: ${arr[1]} ${cyan}| Length: ${arr[2]} ${cyan}| Interval: ${arr[3]} ${green}-> ${white}${arr[4]} ms${rest}"
        done
    else
        echo -e "${red}No successful pings recorded. Config might be dead.${rest}"
    fi

    stop_xray_process
    echo -e "${blue}*****************************${rest}"
    echo -en "${green}Press Enter to return to menu...${rest}"
    read -r
}

# ADD FRAGMENT TO CONFIG (Using JQ)
config2Fragment() {
    echo -en "${green}Enter your Config [${yellow}VLESS${cyan}/${yellow}VMESS${cyan}/${yellow}TROJAN${green}][${yellow}Ws${cyan}/${yellow}Grpc${green}]: ${rest}"
    read -r link

    local protocol="" network="" address="" port="" uuid="" path="" security=""
    local host="" fp="" sni="" name="" pass="" serviceName="" multiMode="false"

    if [[ $link == "vmess://"* ]]; then
        protocol="vmess"
        vmess_config=$(echo "${link#vmess://}" | base64 -d 2>/dev/null)
        address=$(echo "$vmess_config" | jq -r '.add')
        port=$(echo "$vmess_config" | jq -r '.port')
        uuid=$(echo "$vmess_config" | jq -r '.id')
        path=$(echo "$vmess_config" | jq -r '.path // empty')
        network=$(echo "$vmess_config" | jq -r '.net')
        host=$(echo "$vmess_config" | jq -r '.host // empty')
        fp=$(echo "$vmess_config" | jq -r '.fp // empty')
        sni=$(echo "$vmess_config" | jq -r '.sni // empty')
        name=$(echo "$vmess_config" | jq -r '.ps // "VMess-Frag"')
        security=$(echo "$vmess_config" | jq -r '.tls // empty')
        [[ $(echo "$vmess_config" | jq -r '.type') == "multi" ]] && multiMode="true"

    elif [[ $link == "vless://"* ]]; then
        protocol="vless"
        uuid=$(echo "$link" | sed -n 's|^vless://\([a-z0-9\-]*\)@.*|\1|p')
        address=$(echo "$link" | sed -n 's|^vless://[a-z0-9\-]*@\([^:]*\):.*|\1|p')
        port=$(echo "$link" | sed -n 's|.*:\([0-9]*\).*|\1|p')
        path=$(echo "$link" | sed -n 's|.*path=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
        network=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p')
        security=$(echo "$link" | sed -n 's|.*security=\([^&]*\).*|\1|p')
        host=$(echo "$link" | sed -n 's|.*host=\([^&]*\).*|\1|p')
        fp=$(echo "$link" | sed -n 's|.*fp=\([^&]*\).*|\1|p')
        sni=$(echo "$link" | sed -n 's|.*sni=\([^&]*\).*|\1|p' | sed 's|#.*||')
        name=$(echo "$link" | sed 's|^.*#||')
        serviceName=$(echo "$link" | sed -n 's|.*serviceName=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
        [[ $link == *"mode=multi"* ]] && multiMode="true"

    elif [[ $link == "trojan://"* ]]; then
        protocol="trojan"
        pass=$(echo "$link" | sed -n 's|^trojan://\([^@]*\)@.*|\1|p')
        address=$(echo "$link" | sed -n 's|^trojan://[^@]*@\([^:]*\):.*|\1|p')
        port=$(echo "$link" | sed -n 's|.*:\([0-9]*\)?.*|\1|p')
        path=$(echo "$link" | sed -n 's|.*path=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
        network=$(echo "$link" | sed -n 's|.*type=\([^&]*\).*|\1|p')
        security=$(echo "$link" | sed -n 's|.*security=\([^&]*\).*|\1|p')
        host=$(echo "$link" | sed -n 's|.*host=\([^&]*\).*|\1|p')
        fp=$(echo "$link" | sed -n 's|.*fp=\([^&]*\).*|\1|p')
        sni=$(echo "$link" | sed -n 's|.*sni=\([^&]*\).*|\1|p' | sed 's|#.*||')
        name=$(echo "$link" | sed 's|^.*#||')
        serviceName=$(echo "$link" | sed -n 's|.*serviceName=\([^&]*\).*|\1|p' | sed 's|%2F|/|g')
        [[ $link == *"mode=multi"* ]] && multiMode="true"
    else
        echo -e "${red}Unsupported or invalid link.${rest}"
        return
    fi

    echo -e "${yellow}Generating secure JSON config via jq...${rest}"

    local def_packets="tlshello" def_length="1-3" def_interval="5-10"
    if [[ "$security" != "tls" ]]; then
        def_packets="1-1" def_length="5-10" def_interval="10-20"
    fi

    jq -n \
        --arg name "$name+Fragment" \
        --arg proto "$protocol" \
        --arg addr "$address" \
        --argjson p "$port" \
        --arg id "$uuid" \
        --arg pass "$pass" \
        --arg net "$network" \
        --arg path "$path" \
        --arg host "$host" \
        --arg sni "$sni" \
        --arg sec "$security" \
        --arg fp "$fp" \
        --arg svc "$serviceName" \
        --arg multi "$multiMode" \
        --arg dpk "$def_packets" --arg dln "$def_length" --arg dit "$def_interval" \
    '{
      remarks: $name,
      log: { loglevel: "warning" },
      inbounds: [
        { tag: "socks", port: 10808, listen: "127.0.0.1", protocol: "socks", settings: { auth: "noauth", udp: true } },
        { tag: "http", port: 10809, listen: "127.0.0.1", protocol: "http", settings: { auth: "noauth", udp: true } }
      ],
      outbounds: [
        {
          tag: "proxy",
          protocol: $proto,
          settings: (if $proto == "trojan" then 
            { servers: [{ address: $addr, password: $pass, port: $p }] } 
          else 
            { vnext: [{ address: $addr, port: $p, users: [{ id: $id, alterId: 0, security: "auto", encryption: "none" }] }] } 
          end),
          streamSettings: {
            network: $net,
            security: (if $sec == "tls" then "tls" else "none" end),
            tlsSettings: (if $sec == "tls" then {
                allowInsecure: false,
                serverName: $sni,
                fingerprint: ($fp // "chrome"),
                alpn: ["h2", "http/1.1"]
            } else null end),
            wsSettings: (if $net == "ws" then { path: $path, headers: { Host: $host } } else null end),
            grpcSettings: (if $net == "grpc" then { multiMode: ($multi == "true"), serviceName: $svc } else null end)
          },
          sockopt: { dialerProxy: "fragment", tcpFastOpen: true, tcpNoDelay: true }
        },
        {
          tag: "fragment",
          protocol: "freedom",
          settings: {
            domainStrategy: "AsIs",
            fragment: { packets: $dpk, length: $dln, interval: $dit }
          }
        },
        { tag: "direct", protocol: "freedom" },
        { tag: "block", protocol: "blackhole" }
      ],
      routing: { domainStrategy: "AsIs", rules: [ { type: "field", port: "0-65535", outboundTag: "proxy" } ] }
    }' > config.json

    if [ $? -eq 0 ]; then
        echo -e "${green}Config successfully generated and saved in ${yellow}config.json${rest}"
    else
        echo -e "${red}Failed to generate config.json!${rest}"
    fi
    
    echo -en "${green}Press Enter to return to menu...${rest}"
    read -r
}

# Main Menu Loop
while true; do
    clear
    echo -e "${cyan}By --> Peyman * Github.com/Ptechgithub * ${rest}"
    echo ""
    echo -e "${yellow}************************${rest}"
    echo -e "${yellow}*    ${purple}Fragment Tools${yellow}    *${rest}"
    echo -e "${yellow}************************${rest}"
    echo -e "${yellow}[${green}1${yellow}] ${green}Config To fragment${yellow} * ${rest}"
    echo -e "${yellow}                       *${rest}"
    echo -e "${yellow}[${green}2${yellow}] ${green}Fragment Scanner${yellow}   * ${rest}"
    echo -e "${yellow}                       *${rest}"
    echo -e "${yellow}[${red}0${yellow}] Exit               *${rest}"
    echo -e "${yellow}************************${rest}"
    echo -en "${cyan}Enter your choice: ${rest}"
    read -r choice
    
    case "$choice" in
        1) config2Fragment ;;
        2) fragment_scanner ;;
        0) 
            echo -e "${yellow}************************${rest}"
            echo -e "${cyan}Goodbye!${rest}"
            pkill -f "xray run" 2>/dev/null
            exit 
            ;;
        *) 
            echo -e "${yellow}********************${rest}"
            echo -e "${red}Invalid choice.${rest}"
            sleep 1
            ;;
    esac
done
