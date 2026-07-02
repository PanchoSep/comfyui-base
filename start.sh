#!/bin/bash
set -e  # Exit the script if any statement returns a non-true return value

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
OLD_VENV_DIR="$COMFYUI_DIR/.venv"
FILEBROWSER_CONFIG="/root/.config/filebrowser/config.json"
DB_FILE="/workspace/runpod-slim/filebrowser.db"
PIP_CONSTRAINT_FILE="/opt/comfyui-runtime-constraints.txt"

# ---------------------------------------------------------------------------- #
#                          Function Definitions                                  #
# ---------------------------------------------------------------------------- #

# Setup SSH with optional key or random password
setup_ssh() {
    mkdir -p ~/.ssh
    
    if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
        ssh-keygen -A -q
    fi

    # If PUBLIC_KEY is provided, use it
    if [[ $PUBLIC_KEY ]]; then
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 -R ~/.ssh
    else
        # Generate random password if no public key
        RANDOM_PASS=$(openssl rand -base64 12)
        echo "root:${RANDOM_PASS}" | chpasswd
        echo "Generated random SSH password for root: ${RANDOM_PASS}"
    fi

    # Configure SSH to preserve environment variables
    echo "PermitUserEnvironment yes" >> /etc/ssh/sshd_config

    # Start SSH service
    /usr/sbin/sshd
}

# Export environment variables
export_env_vars() {
    echo "Exporting environment variables..."
    
    # Create environment files
    ENV_FILE="/etc/environment"
    PAM_ENV_FILE="/etc/security/pam_env.conf"
    SSH_ENV_DIR="/root/.ssh/environment"
    
    # Backup original files
    cp "$ENV_FILE" "${ENV_FILE}.bak" 2>/dev/null || true
    cp "$PAM_ENV_FILE" "${PAM_ENV_FILE}.bak" 2>/dev/null || true
    
    # Clear files
    > "$ENV_FILE"
    > "$PAM_ENV_FILE"
    mkdir -p /root/.ssh
    > "$SSH_ENV_DIR"
    
    # Export to multiple locations for maximum compatibility
    printenv | grep -E '^RUNPOD_|^PATH=|^_=|^CUDA|^LD_LIBRARY_PATH|^PYTHONPATH|^PIP_CONSTRAINT=' | while read -r line; do
        # Get variable name and value
        name=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)
        
        # Add to /etc/environment (system-wide)
        echo "$name=\"$value\"" >> "$ENV_FILE"
        
        # Add to PAM environment
        echo "$name DEFAULT=\"$value\"" >> "$PAM_ENV_FILE"
        
        # Add to SSH environment file
        echo "$name=\"$value\"" >> "$SSH_ENV_DIR"
        
        # Add to current shell
        echo "export $name=\"$value\"" >> /etc/rp_environment
    done
    
    # Add sourcing to shell startup files
    echo 'source /etc/rp_environment' >> ~/.bashrc
    echo 'source /etc/rp_environment' >> /etc/bash.bashrc
    
    # Set permissions
    chmod 644 "$ENV_FILE" "$PAM_ENV_FILE"
    chmod 600 "$SSH_ENV_DIR"
}

# Start Jupyter Lab server for remote access
start_jupyter() {
    mkdir -p /workspace
    echo "Starting Jupyter Lab on port 8888..."
    nohup jupyter lab \
        --allow-root \
        --no-browser \
        --port=8888 \
        --ip=0.0.0.0 \
        --FileContentsManager.delete_to_trash=False \
        --FileContentsManager.preferred_dir=/workspace \
        --ServerApp.root_dir=/workspace \
        --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
        --IdentityProvider.token="${JUPYTER_PASSWORD:-}" \
        --ServerApp.allow_origin=* &> /jupyter.log &
    echo "Jupyter Lab started"
}

# ---------------------------------------------------------------------------- #
#                               Main Program                                     #
# ---------------------------------------------------------------------------- #

# Setup environment
if [ -f "$PIP_CONSTRAINT_FILE" ]; then
    export PIP_CONSTRAINT="$PIP_CONSTRAINT_FILE"
    echo "Using runtime pip constraints from $PIP_CONSTRAINT_FILE"
fi

setup_ssh
export_env_vars

# Initialize FileBrowser if not already done
if [ ! -f "$DB_FILE" ]; then
    echo "Initializing FileBrowser..."
    filebrowser config init
    filebrowser config set --address 0.0.0.0
    filebrowser config set --port 8080
    filebrowser config set --root /workspace
    filebrowser config set --auth.method=json
    filebrowser users add admin adminadmin12 --perm.admin
else
    echo "Using existing FileBrowser configuration..."
fi

# Start FileBrowser
echo "Starting FileBrowser on port 8080..."
nohup filebrowser &> /filebrowser.log &

start_jupyter

# ---------------------------------------------------------------------------- #
#  Sync Setup — SSH key + rclone + background sync loop (env-var driven)       #
# ---------------------------------------------------------------------------- #
# Controlled entirely by environment variables. If VPS_HOST and VPS_OUTPUT_PATH
# are set, SSH key and rclone are configured and a background sync loop starts.
# Otherwise, this section is a no-op.
setup_sync() {
    VPS_USER="${VPS_USER:-root}"
    VPS_PORT="${VPS_PORT:-22}"
    SYNC_INTERVAL="${SYNC_INTERVAL:-120}"
    NV_DIR="${NETWORK_VOLUME:-/workspace}"
    SSH_KEY_NV="$NV_DIR/ssh/id_ed25519"
    SSH_KEY="/tmp/id_ed25519_sync"
    RCLONE_CONF="$NV_DIR/rclone.conf"
    RCLONE_REMOTE="vps"

    # Nothing to do if VPS host or output path not configured
    if [ -z "${VPS_HOST:-}" ] || [ -z "${VPS_OUTPUT_PATH:-}" ]; then
        echo "Sync: VPS_HOST or VPS_OUTPUT_PATH not set — skipping sync setup"
        return 0
    fi

    echo "============================================="
    echo "  Sync: Configuring → ${VPS_USER}@${VPS_HOST}:${VPS_OUTPUT_PATH}"
    echo "============================================="

    # Ensure rclone is available
    if ! command -v rclone &>/dev/null; then
        echo "Sync: Installing rclone..."
        apt-get update -qq && apt-get install -y -qq rclone 2>/dev/null
    fi

    # SSH key: 3-tier priority
    #   1. SYNC_SSH_KEY env var (pre-generated, pre-authorized on VPS)
    #   2. Existing key in persistent storage
    #   3. Generate new key (requires manual authorization on VPS)
    mkdir -p "$NV_DIR/ssh"

    if [ -n "${SYNC_SSH_KEY:-}" ]; then
        echo "Sync: Using SSH key from SYNC_SSH_KEY env var"
        echo "$SYNC_SSH_KEY" | base64 -d > "$SSH_KEY_NV"
        chmod 600 "$SSH_KEY_NV"
        # Regenerate .pub in case it's missing
        ssh-keygen -y -f "$SSH_KEY_NV" > "${SSH_KEY_NV}.pub" 2>/dev/null
    elif [ -f "$SSH_KEY_NV" ]; then
        echo "Sync: Using existing SSH key from $SSH_KEY_NV"
    else
        echo "Sync: Generating new SSH ed25519 key..."
        ssh-keygen -t ed25519 -f "$SSH_KEY_NV" -N "" -C "comfyui-sync" -q
        PUBKEY=$(cat "${SSH_KEY_NV}.pub")
        echo ""
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║  SYNC: Authorize this key on your VPS               ║"
        echo "╠══════════════════════════════════════════════════════╣"
        echo "║  Run on VPS (${VPS_HOST}):"
        echo "║  echo '${PUBKEY}' >> ~/.ssh/authorized_keys"
        echo "╚══════════════════════════════════════════════════════╝"
        echo ""
    fi

    # Copy to /tmp (persistent storage may not support chmod)
    cp "$SSH_KEY_NV" "$SSH_KEY"
    chmod 600 "$SSH_KEY"

    # Test SSH connection (non-fatal)
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -o BatchMode=yes -p "$VPS_PORT" "${VPS_USER}@${VPS_HOST}" "echo ok" &>/dev/null; then
        echo "Sync: SSH connection to VPS verified ✓"
    else
        echo "Sync: WARNING — Cannot SSH to VPS (key may not be authorized yet)"
        echo "Sync: Loop will start but syncs will fail until key is authorized"
    fi

    # Configure rclone
    rclone config delete "$RCLONE_REMOTE" --config "$RCLONE_CONF" -q 2>/dev/null || true
    rclone config create "$RCLONE_REMOTE" sftp \
        host "$VPS_HOST" \
        user "$VPS_USER" \
        port "$VPS_PORT" \
        key_file "$SSH_KEY" \
        shell_type unix \
        --config "$RCLONE_CONF" -q 2>&1

    rclone --config "$RCLONE_CONF" mkdir "${RCLONE_REMOTE}:${VPS_OUTPUT_PATH#/}" 2>/dev/null || true
    echo "Sync: rclone configured (${RCLONE_REMOTE}:${VPS_OUTPUT_PATH})"

    # Start background sync loop
    echo "Sync: Starting background sync loop every ${SYNC_INTERVAL}s..."
    (
        while true; do
            sleep "$SYNC_INTERVAL"
            rclone --config "$RCLONE_CONF" sync \
                "$COMFYUI_DIR/output" \
                "${RCLONE_REMOTE}:${VPS_OUTPUT_PATH#/}" \
                --transfers 4 --checkers 8 \
                --ignore-existing \
                2>&1 | while IFS= read -r line; do
                    echo "[sync] $line"
                done
        done
    ) &
    echo "Sync: Background sync PID: $!"
}

setup_sync
echo ""

# Create default comfyui_args.txt if it doesn't exist
ARGS_FILE="/workspace/runpod-slim/comfyui_args.txt"
if [ ! -f "$ARGS_FILE" ]; then
    echo "# Add your custom ComfyUI arguments here (one per line)" > "$ARGS_FILE"
    echo "Created empty ComfyUI arguments file at $ARGS_FILE"
fi

# Migrate old CUDA 12.4 venv to cu128
if [ -d "$OLD_VENV_DIR" ] && [ ! -d "$VENV_DIR" ]; then
    NODE_COUNT=$(find "$COMFYUI_DIR/custom_nodes" -maxdepth 2 -name "requirements.txt" 2>/dev/null | wc -l)
    echo "============================================="
    echo "  CUDA 12.4 -> 12.8 migration"
    echo "  Reinstalling deps for $NODE_COUNT custom nodes"
    echo "  This may take several minutes"
    echo "============================================="
    mv "$OLD_VENV_DIR" "${OLD_VENV_DIR}.bak"
    cd "$COMFYUI_DIR"
    python3.12 -m venv --system-site-packages "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    python -m ensurepip
    # Skip nodes baked into the image — their deps are in system site-packages
    BAKED_NODES="ComfyUI-Manager ComfyUI-KJNodes Civicomfy ComfyUI-RunpodDirect ComfyUI-INT8-Fast ControlAltAI-Nodes CRT-Nodes ComfyUI-Login"
    CURRENT=0
    INSTALLED=0
    for req in "$COMFYUI_DIR"/custom_nodes/*/requirements.txt; do
        if [ -f "$req" ]; then
            NODE_NAME=$(basename "$(dirname "$req")")
            case " $BAKED_NODES " in
                *" $NODE_NAME "*) continue ;;
            esac
            CURRENT=$((CURRENT + 1))
            echo "[$CURRENT] $NODE_NAME"
            pip install -r "$req" 2>&1 | grep -E "^(Successfully|ERROR)" || true
            INSTALLED=$((INSTALLED + 1))
        fi
    done
    echo "Ensuring ComfyUI requirements are present..."
    pip install -r "$COMFYUI_DIR/requirements.txt" 2>&1 | grep -E "^(Successfully|ERROR)" || true
    echo "Migration complete — $INSTALLED user nodes processed (${NODE_COUNT} total, baked nodes skipped)"
    echo "Old venv backed up at ${OLD_VENV_DIR}.bak — delete it to free space:"
    echo "  rm -rf ${OLD_VENV_DIR}.bak"
fi

# Setup ComfyUI if needed
if [ ! -d "$COMFYUI_DIR" ] || [ ! -d "$VENV_DIR" ]; then
    echo "First time setup: Copying baked ComfyUI to workspace..."

    # Copy baked ComfyUI from image (no git, no network)
    if [ ! -d "$COMFYUI_DIR" ]; then
        cp -r /opt/comfyui-baked "$COMFYUI_DIR"
        echo "ComfyUI copied to workspace"
    fi

    # Create venv with access to system packages (torch, numpy, etc. pre-installed in image)
    if [ ! -d "$VENV_DIR" ]; then
        cd "$COMFYUI_DIR"
        python3.12 -m venv --system-site-packages "$VENV_DIR"
        source "$VENV_DIR/bin/activate"

        # Ensure pip is available in the venv (needed for ComfyUI-Manager)
        python -m ensurepip

        echo "Base packages (torch, numpy, etc.) available from system site-packages"
        echo "ComfyUI ready — all dependencies pre-installed in image"
    fi
else
    # Just activate the existing venv
    source "$VENV_DIR/bin/activate"
    echo "Using existing ComfyUI installation"
fi

# Warm up pip so ComfyUI-Manager's 5s timeout check doesn't fail on cold start
python -m pip --version > /dev/null 2>&1

# Start ComfyUI — keep container alive if it crashes so SSH/Jupyter remain accessible
cd $COMFYUI_DIR
FIXED_ARGS="--listen 0.0.0.0 --port 8188 --enable-cors-header"
if [ -s "$ARGS_FILE" ]; then
    CUSTOM_ARGS=$(grep -v '^#' "$ARGS_FILE" | tr '\n' ' ')
    if [ ! -z "$CUSTOM_ARGS" ]; then
        FIXED_ARGS="$FIXED_ARGS $CUSTOM_ARGS"
    fi
fi

echo "Starting ComfyUI with args: $FIXED_ARGS"
python main.py $FIXED_ARGS &
COMFY_PID=$!
trap "kill $COMFY_PID 2>/dev/null" SIGTERM SIGINT
wait $COMFY_PID || true

echo "============================================="
echo "  ComfyUI crashed — check the logs above."
echo "  SSH and JupyterLab are still available."
echo "  To restart after fixing:"
echo "    cd $COMFYUI_DIR && source .venv-cu128/bin/activate"
echo "    python main.py $FIXED_ARGS"
echo "============================================="

sleep infinity
