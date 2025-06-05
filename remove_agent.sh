#!/bin/bash

# =============================================================================
# MONITOR AGENT REMOVAL SCRIPT
# =============================================================================
# This script completely removes the monitor agent installation including:
# - Stopping and disabling the systemd service
# - Removing the monitor user and home directory
# - Cleaning up configuration files
# - Removing sudoers rules
# - Uninstalling Python dependencies (optional)
# - Removing the agent script
# =============================================================================

# Configuration (should match setup_agent.sh)
USER_NAME="monitor-agent"
AGENT_SCRIPT="/usr/local/bin/monitor.py"
CONFIG_FILE="/etc/monitor.conf"
SERVICE_FILE="/etc/systemd/system/monitor.service"
SUDOERS_FILE="/etc/sudoers.d/monitor-agent-arp-scan"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Function to confirm removal
confirm_removal() {
    echo -e "${YELLOW}⚠️  WARNING: This will completely remove the monitor agent!${NC}"
    echo "This includes:"
    echo "  - Stopping and removing the monitor service"
    echo "  - Removing the monitor-agent user and home directory"
    echo "  - Cleaning up all configuration files"
    echo "  - Removing sudoers rules"
    echo ""
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Removal cancelled by user"
        exit 0
    fi
}

# Function to stop and disable service
stop_service() {
    print_status "Stopping and disabling monitor service..."
    
    if systemctl is-active --quiet monitor.service; then
        systemctl stop monitor.service
        print_success "Service stopped"
    else
        print_warning "Service was not running"
    fi
    
    if systemctl is-enabled --quiet monitor.service; then
        systemctl disable monitor.service
        print_success "Service disabled"
    else
        print_warning "Service was not enabled"
    fi
    
    # Reload systemd daemon
    systemctl daemon-reload
    print_success "Systemd daemon reloaded"
}

# Function to remove service file
remove_service_file() {
    print_status "Removing service file..."
    
    if [[ -f "$SERVICE_FILE" ]]; then
        rm -f "$SERVICE_FILE"
        print_success "Service file removed: $SERVICE_FILE"
    else
        print_warning "Service file not found: $SERVICE_FILE"
    fi
}

# Function to remove user
remove_user() {
    print_status "Removing monitor user..."
    
    if id "$USER_NAME" &>/dev/null; then
        # Kill any running processes by the user
        pkill -u "$USER_NAME" 2>/dev/null || true
        
        # Remove user and home directory
        userdel -r "$USER_NAME" 2>/dev/null || {
            # If userdel fails, try manual cleanup
            userdel "$USER_NAME" 2>/dev/null || true
            rm -rf "/home/$USER_NAME" 2>/dev/null || true
        }
        print_success "User $USER_NAME removed"
    else
        print_warning "User $USER_NAME not found"
    fi
}

# Function to remove agent script
remove_agent_script() {
    print_status "Removing agent script..."
    
    if [[ -f "$AGENT_SCRIPT" ]]; then
        rm -f "$AGENT_SCRIPT"
        print_success "Agent script removed: $AGENT_SCRIPT"
    else
        print_warning "Agent script not found: $AGENT_SCRIPT"
    fi
}

# Function to remove configuration file
remove_config_file() {
    print_status "Removing configuration file..."
    
    if [[ -f "$CONFIG_FILE" ]]; then
        rm -f "$CONFIG_FILE"
        print_success "Configuration file removed: $CONFIG_FILE"
    else
        print_warning "Configuration file not found: $CONFIG_FILE"
    fi
}

# Function to remove sudoers rule
remove_sudoers_rule() {
    print_status "Removing sudoers rule..."
    
    if [[ -f "$SUDOERS_FILE" ]]; then
        rm -f "$SUDOERS_FILE"
        print_success "Sudoers rule removed: $SUDOERS_FILE"
    else
        print_warning "Sudoers file not found: $SUDOERS_FILE"
    fi
}

# Function to reset arp-scan capabilities
reset_arp_scan_capabilities() {
    print_status "Resetting arp-scan capabilities..."
    
    if command -v setcap >/dev/null 2>&1; then
        setcap -r /usr/bin/arp-scan 2>/dev/null || true
        print_success "arp-scan capabilities reset"
    else
        print_warning "setcap not available, skipping capability reset"
    fi
}

# Function to optionally remove Python packages
remove_python_packages() {
    print_status "Checking Python packages..."
    
    echo "The following Python packages were installed for the monitor agent:"
    echo "  - websocket-client"
    echo "  - psutil"
    echo "  - requests"
    echo ""
    read -p "Do you want to remove these Python packages? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Removing Python packages..."
        pip3 uninstall -y websocket-client psutil requests 2>/dev/null || {
            print_warning "Some packages may not have been installed via pip3"
        }
        print_success "Python packages removal attempted"
    else
        print_warning "Python packages left installed (they may be used by other applications)"
    fi
}

# Function to optionally remove system packages
remove_system_packages() {
    print_status "Checking system packages..."
    
    echo "The following system packages were installed for the monitor agent:"
    echo "  - arp-scan"
    echo "  - net-tools"
    echo ""
    read -p "Do you want to remove these system packages? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Removing system packages..."
        apt remove -y arp-scan net-tools 2>/dev/null || {
            print_warning "Some packages may not have been installed or are used by other applications"
        }
        print_success "System packages removal attempted"
    else
        print_warning "System packages left installed (they may be used by other applications)"
    fi
}

# Function to clean up any remaining files
cleanup_remaining_files() {
    print_status "Cleaning up any remaining files..."
    
    # Check for any remaining monitor-related files
    remaining_files=$(find /etc /usr/local /var/log -name "*monitor*" -type f 2>/dev/null | grep -v "monit" | head -10)
    
    if [[ -n "$remaining_files" ]]; then
        print_warning "Found potential remaining files:"
        echo "$remaining_files"
        echo ""
        read -p "Do you want to review and potentially remove these files? (y/N): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "$remaining_files" | while read -r file; do
                if [[ -f "$file" ]]; then
                    echo "File: $file"
                    read -p "Remove this file? (y/N): " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        rm -f "$file"
                        print_success "Removed: $file"
                    fi
                fi
            done
        fi
    else
        print_success "No obvious remaining files found"
    fi
}

# Function to send removal notification
send_removal_notification() {
    print_status "Attempting to send removal notification..."
    
    # Try to read config for debug API
    DEBUG_API_URL=""
    if [[ -f "$CONFIG_FILE" ]]; then
        DEBUG_API_URL=$(grep "DEBUG_API_URL=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2)
    fi
    
    if [[ -n "$DEBUG_API_URL" ]]; then
        SERVER_ID=$(hostname)
        curl -s -X POST "$DEBUG_API_URL" \
            -H "Content-Type: application/json" \
            -d "{\"server_id\": \"$SERVER_ID\", \"message\": \"Monitor agent removed from server\"}" \
            >/dev/null 2>&1 && print_success "Removal notification sent" || print_warning "Failed to send removal notification"
    else
        print_warning "Debug API URL not found, skipping removal notification"
    fi
}

# Main removal function
main() {
    echo "=============================================="
    echo "    MONITOR AGENT REMOVAL SCRIPT"
    echo "=============================================="
    echo ""
    
    # Check if running as root
    check_root
    
    # Confirm removal
    confirm_removal
    
    echo ""
    print_status "Starting monitor agent removal process..."
    echo ""
    
    # Send removal notification (before removing config)
    send_removal_notification
    
    # Stop and remove service
    stop_service
    remove_service_file
    
    # Remove files and configurations
    remove_agent_script
    remove_config_file
    remove_sudoers_rule
    
    # Reset capabilities
    reset_arp_scan_capabilities
    
    # Remove user (after stopping service)
    remove_user
    
    # Optional package removal
    echo ""
    remove_python_packages
    echo ""
    remove_system_packages
    
    # Clean up remaining files
    echo ""
    cleanup_remaining_files
    
    echo ""
    print_success "Monitor agent removal completed!"
    echo ""
    print_status "Summary of what was removed:"
    echo "  ✓ Monitor service stopped and disabled"
    echo "  ✓ Service file removed"
    echo "  ✓ Agent script removed"
    echo "  ✓ Configuration file removed"
    echo "  ✓ Sudoers rule removed"
    echo "  ✓ User '$USER_NAME' removed"
    echo "  ✓ arp-scan capabilities reset"
    echo ""
    print_warning "Note: Some system packages may have been left installed if they"
    print_warning "are used by other applications. This is normal and safe."
    echo ""
}

# Run main function
main "$@"
