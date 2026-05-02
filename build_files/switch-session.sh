#!/bin/bash

# NASy-Peasy Session Manager
# Used for switching between LXQt and Plasma Bigscreen

CONFIG_FILE="/etc/switch-session.conf"
VNC_SERVICE="/etc/systemd/system/vncserver.service"

set_session() {
    local session=$1
    echo "Setting default session to: $session"
    
    case "$session" in
        lxqt)
            echo "SESSION=lxqt" > "$CONFIG_FILE"
            # Update VNC startup logic or xinitrc if necessary
            ;;
        plasma)
            echo "SESSION=plasma" > "$CONFIG_FILE"
            ;;
        *)
            echo "Unknown session: $session. Use 'lxqt' or 'plasma'."
            exit 1
            ;;
    esac
    
    # Trigger app cleanup to ensure isolation
    clean_apps
}

clean_apps() {
    echo "Isolating applications between DEs..."
    
    # We'll use a simple heuristic:
    # 1. LXQt specific apps get OnlyShowIn=LXQt
    # 2. KDE/Plasma specific apps get OnlyShowIn=KDE
    
    # Common KDE apps
    local kde_apps=("dolphin" "konsole" "systemsettings" "okular" "gwenview" "ark" "kate")
    # Common LXQt apps
    local lxqt_apps=("pcmanfm-qt" "qterminal" "lxqt-config" "featherpad" "screengrab")

    for app in "${kde_apps[@]}"; do
        patch_desktop "$app" "KDE"
    done

    for app in "${lxqt_apps[@]}"; do
        patch_desktop "$app" "LXQt"
    done
    
    # Also hide "Bigscreen" apps from standard LXQt
    patch_desktop "plasma-bigscreen" "KDE"
}

patch_desktop() {
    local app_name=$1
    local de=$2
    local file
    
    file=$(find /usr/share/applications -name "*${app_name}*.desktop" | head -n 1)
    
    if [[ -n "$file" ]]; then
        echo "Patching $file for $de..."
        # Remove existing tags
        sed -i '/^OnlyShowIn=/d' "$file"
        sed -i '/^NotShowIn=/d' "$file"
        # Add new tag
        echo "OnlyShowIn=$de;" >> "$file"
    fi
}

show_status() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo "Current default session: $SESSION"
    else
        echo "No default session set. Defaulting to LXQt."
    fi
}

case "$1" in
    set)
        set_session "$2"
        ;;
    clean)
        clean_apps
        ;;
    status)
        show_status
        ;;
    *)
        echo "Usage: switch-session {set lxqt|plasma | clean | status}"
        exit 1
        ;;
esac
