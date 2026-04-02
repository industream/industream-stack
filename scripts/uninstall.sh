#!/bin/bash
# =============================================================================
# INDUSTREAM PLATFORM - UNINSTALL / TEARDOWN
# =============================================================================
# Cleanly remove Industream resources (stacks, volumes, secrets, networks).
#
# Usage:
#   ./scripts/uninstall.sh --env prod              # Remove one environment
#   ./scripts/uninstall.sh --all                    # Remove everything
#   ./scripts/uninstall.sh --env prod --dry-run     # Show what would be deleted
#   ./scripts/uninstall.sh --env prod --force       # Skip confirmation prompts
#   ./scripts/uninstall.sh --all --delete-data      # Also remove secrets/, .env, certs/
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

# Defaults
ENV=""
ALL=false
FORCE=false
DRY_RUN=false
DELETE_DATA=false

# Change to project directory
cd "$PROJECT_DIR"

# =============================================================================
# Parse arguments
# =============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --env)
            ENV="$2"
            shift 2
            ;;
        --all)
            ALL=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delete-data)
            DELETE_DATA=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--env <prod|dev|staging> | --all] [OPTIONS]"
            echo ""
            echo "Target (one required):"
            echo "  --env <env>      Environment to remove (prod, dev, staging)"
            echo "  --all            Remove all environments + shared infrastructure"
            echo ""
            echo "Options:"
            echo "  --force          Skip confirmation prompts"
            echo "  --dry-run        Show what would be deleted without deleting"
            echo "  --delete-data    Also remove secrets/, .env files, certs/ directory"
            echo "  --help, -h       Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 --env dev                      # Remove dev environment"
            echo "  $0 --env prod --dry-run            # Preview prod removal"
            echo "  $0 --all --force                   # Remove everything, no prompts"
            echo "  $0 --all --force --delete-data     # Full cleanup including local files"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# =============================================================================
# Validate arguments
# =============================================================================
if [ -z "$ENV" ] && [ "$ALL" = "false" ]; then
    echo -e "${RED}Error: specify --env <prod|dev|staging> or --all${NC}"
    echo "Use --help for usage information"
    exit 1
fi

if [ -n "$ENV" ] && [ "$ALL" = "true" ]; then
    echo -e "${RED}Error: --env and --all are mutually exclusive${NC}"
    exit 1
fi

if [ -n "$ENV" ] && [[ ! "$ENV" =~ ^(prod|dev|staging)$ ]]; then
    echo -e "${RED}Error: invalid environment: $ENV${NC}"
    echo "Valid environments: prod, dev, staging"
    exit 1
fi

# =============================================================================
# Helpers
# =============================================================================
confirm() {
    local message="$1"
    if [ "$FORCE" = "true" ]; then
        return 0
    fi
    echo ""
    read -p "$(echo -e "${YELLOW}${message} [y/N]: ${NC}")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

run_or_dry() {
    local description="$1"
    shift
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}  [dry-run] $description${NC}"
        echo -e "${BLUE}    → $*${NC}"
    else
        echo -e "${BLUE}  $description${NC}"
        "$@"
    fi
}

wait_for_stack_drain() {
    local stack_name="$1"
    local max_wait=60
    local elapsed=0

    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}  [dry-run] Would wait for stack '${stack_name}' to drain${NC}"
        return 0
    fi

    echo -e "${BLUE}  Waiting for stack '${stack_name}' services to drain...${NC}"
    while [ $elapsed -lt $max_wait ]; do
        # Check if any tasks still exist for this stack
        local remaining
        remaining=$(docker stack ps "$stack_name" --format "{{.ID}}" 2>/dev/null | wc -l)
        if [ "$remaining" -eq 0 ]; then
            echo -e "${GREEN}  ✓ Stack '${stack_name}' fully drained${NC}"
            return 0
        fi
        echo -e "${YELLOW}    ${remaining} task(s) remaining... (${elapsed}s/${max_wait}s)${NC}"
        sleep 3
        elapsed=$((elapsed + 3))
    done

    echo -e "${YELLOW}  ⚠ Stack drain timed out after ${max_wait}s (some resources may linger)${NC}"
}

# =============================================================================
# Detect environments
# =============================================================================
detect_environments() {
    local envs=()
    for candidate in prod dev staging; do
        if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -q "^industream-${candidate}$"; then
            envs+=("$candidate")
        fi
    done
    echo "${envs[@]}"
}

# =============================================================================
# Remove a single environment
# =============================================================================
remove_environment() {
    local env="$1"
    local stack_name="industream-${env}"

    echo ""
    echo -e "${RED}══════════════════════════════════════════════════${NC}"
    echo -e "${RED}   Removing: ${env^^} environment${NC}"
    echo -e "${RED}══════════════════════════════════════════════════${NC}"

    # --- Step 1: Remove Docker stack ---
    echo ""
    echo -e "${BOLD}Step 1/5: Docker stack${NC}"
    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -q "^${stack_name}$"; then
        run_or_dry "Removing stack '${stack_name}'" docker stack rm "$stack_name"
        wait_for_stack_drain "$stack_name"
    else
        echo -e "${YELLOW}  Stack '${stack_name}' not found (already removed or never deployed)${NC}"
    fi

    # --- Step 2: Remove Docker secrets ---
    echo ""
    echo -e "${BOLD}Step 2/5: Docker secrets${NC}"
    local secrets
    secrets=$(docker secret ls --format '{{.Name}}' 2>/dev/null | grep "^${env}_" || true)
    if [ -n "$secrets" ]; then
        local secret_count
        secret_count=$(echo "$secrets" | wc -l)
        echo -e "${BLUE}  Found ${secret_count} secret(s) matching '${env}_*':${NC}"
        echo "$secrets" | while read -r s; do echo -e "    - $s"; done
        for s in $secrets; do
            run_or_dry "Removing secret '${s}'" docker secret rm "$s"
        done
        [ "$DRY_RUN" = "false" ] && echo -e "${GREEN}  ✓ Secrets removed${NC}"
    else
        echo -e "${YELLOW}  No secrets found matching '${env}_*'${NC}"
    fi

    # --- Step 3: Remove Docker volumes ---
    echo ""
    echo -e "${BOLD}Step 3/5: Docker volumes${NC}"
    local volumes
    volumes=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep "^${env}-" || true)
    if [ -n "$volumes" ]; then
        local volume_count
        volume_count=$(echo "$volumes" | wc -l)
        echo -e "${RED}  Found ${volume_count} volume(s) matching '${env}-*':${NC}"
        echo "$volumes" | while read -r v; do echo -e "    - $v"; done
        echo ""
        echo -e "${RED}  ⚠  WARNING: Volumes contain databases and persistent data.${NC}"
        echo -e "${RED}     This action is IRREVERSIBLE.${NC}"
        if confirm "Delete ${volume_count} volume(s) for ${env}?"; then
            for v in $volumes; do
                run_or_dry "Removing volume '${v}'" docker volume rm "$v"
            done
            [ "$DRY_RUN" = "false" ] && echo -e "${GREEN}  ✓ Volumes removed${NC}"
        else
            echo -e "${YELLOW}  Skipped volume deletion${NC}"
        fi
    else
        echo -e "${YELLOW}  No volumes found matching '${env}-*'${NC}"
    fi

    # --- Step 4: Remove Docker network ---
    echo ""
    echo -e "${BOLD}Step 4/5: Docker network${NC}"
    local network="${env}-platform"
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${network}$"; then
        run_or_dry "Removing network '${network}'" docker network rm "$network"
        [ "$DRY_RUN" = "false" ] && echo -e "${GREEN}  ✓ Network removed${NC}"
    else
        echo -e "${YELLOW}  Network '${network}' not found${NC}"
    fi

    # --- Step 5: Remove generated files ---
    echo ""
    echo -e "${BOLD}Step 5/5: Generated files${NC}"
    local files_removed=0
    for file in "docker-stack-resolved-${env}.yml" "docker-stack.workers-legacy.yml"; do
        if [ -f "$file" ]; then
            run_or_dry "Removing '${file}'" rm -f "$file"
            files_removed=$((files_removed + 1))
        fi
    done
    if [ $files_removed -gt 0 ]; then
        [ "$DRY_RUN" = "false" ] && echo -e "${GREEN}  ✓ ${files_removed} generated file(s) removed${NC}"
    else
        echo -e "${YELLOW}  No generated files found${NC}"
    fi

    echo ""
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}[dry-run] ${env^^} environment: no changes made${NC}"
    else
        echo -e "${GREEN}✓ ${env^^} environment removed${NC}"
    fi
}

# =============================================================================
# Remove shared infrastructure (Traefik, etc.)
# =============================================================================
remove_shared() {
    echo ""
    echo -e "${RED}══════════════════════════════════════════════════${NC}"
    echo -e "${RED}   Removing: Shared infrastructure${NC}"
    echo -e "${RED}══════════════════════════════════════════════════${NC}"

    # Traefik stack
    echo ""
    echo -e "${BOLD}Traefik stack${NC}"
    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -q "^traefik-shared$"; then
        run_or_dry "Removing stack 'traefik-shared'" docker stack rm traefik-shared
        wait_for_stack_drain "traefik-shared"
    else
        echo -e "${YELLOW}  Stack 'traefik-shared' not found${NC}"
    fi

    # Traefik network
    echo ""
    echo -e "${BOLD}Traefik network${NC}"
    local traefik_network="traefik-shared_traefik-public"
    if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${traefik_network}$"; then
        run_or_dry "Removing network '${traefik_network}'" docker network rm "$traefik_network"
        [ "$DRY_RUN" = "false" ] && echo -e "${GREEN}  ✓ Traefik network removed${NC}"
    else
        echo -e "${YELLOW}  Network '${traefik_network}' not found${NC}"
    fi

    # Shared volumes (letsencrypt, etc.)
    echo ""
    echo -e "${BOLD}Shared volumes${NC}"
    local shared_volumes
    shared_volumes=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^(letsencrypt-data|traefik-shared)" || true)
    if [ -n "$shared_volumes" ]; then
        echo "$shared_volumes" | while read -r v; do echo -e "    - $v"; done
        for v in $shared_volumes; do
            run_or_dry "Removing volume '${v}'" docker volume rm "$v"
        done
        [ "$DRY_RUN" = "false" ] && echo -e "${GREEN}  ✓ Shared volumes removed${NC}"
    else
        echo -e "${YELLOW}  No shared volumes found${NC}"
    fi

    # /etc/hosts cleanup
    echo ""
    echo -e "${BOLD}/etc/hosts cleanup${NC}"
    if grep -q "industream" /etc/hosts 2>/dev/null; then
        if [ "$DRY_RUN" = "true" ]; then
            echo -e "${BLUE}  [dry-run] Would remove Industream entries from /etc/hosts${NC}"
            grep "industream" /etc/hosts | while read -r line; do
                echo -e "${BLUE}    → $line${NC}"
            done
        else
            if confirm "Remove Industream entries from /etc/hosts? (requires sudo)"; then
                sudo sed -i '/industream/Id' /etc/hosts
                echo -e "${GREEN}  ✓ /etc/hosts cleaned${NC}"
            else
                echo -e "${YELLOW}  Skipped /etc/hosts cleanup${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}  No Industream entries in /etc/hosts${NC}"
    fi

    echo ""
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "${BLUE}[dry-run] Shared infrastructure: no changes made${NC}"
    else
        echo -e "${GREEN}✓ Shared infrastructure removed${NC}"
    fi
}

# =============================================================================
# Remove local data files (secrets/, .env, certs/)
# =============================================================================
remove_local_data() {
    echo ""
    echo -e "${RED}══════════════════════════════════════════════════${NC}"
    echo -e "${RED}   Removing: Local data files${NC}"
    echo -e "${RED}══════════════════════════════════════════════════${NC}"

    local items=()
    [ -d "secrets" ] && items+=("secrets/")
    [ -d "certs" ] && items+=("certs/")
    for f in .env .env.prod .env.dev .env.staging; do
        [ -f "$f" ] && items+=("$f")
    done

    if [ ${#items[@]} -eq 0 ]; then
        echo -e "${YELLOW}  No local data files found${NC}"
        return
    fi

    echo -e "${RED}  The following will be deleted:${NC}"
    for item in "${items[@]}"; do
        echo -e "    - ${item}"
    done

    echo ""
    echo -e "${RED}  ⚠  WARNING: This removes credentials, certificates, and configuration.${NC}"
    echo -e "${RED}     You will need to re-run setup to deploy again.${NC}"

    if confirm "Delete local data files?"; then
        for item in "${items[@]}"; do
            run_or_dry "Removing '${item}'" rm -rf "$item"
        done
        [ "$DRY_RUN" = "false" ] && echo -e "${GREEN}  ✓ Local data files removed${NC}"
    else
        echo -e "${YELLOW}  Skipped local data deletion${NC}"
    fi
}

# =============================================================================
# Main
# =============================================================================
echo -e "${RED}══════════════════════════════════════════════════${NC}"
echo -e "${RED}   Industream Platform - Uninstall${NC}"
echo -e "${RED}══════════════════════════════════════════════════${NC}"

if [ "$DRY_RUN" = "true" ]; then
    echo -e "${BLUE}  Mode: DRY RUN (no changes will be made)${NC}"
fi

if [ "$ALL" = "true" ]; then
    echo -e "${BLUE}  Target: ALL environments + shared infrastructure${NC}"

    DETECTED=$(detect_environments)
    if [ -n "$DETECTED" ]; then
        echo -e "${BLUE}  Detected stacks: ${DETECTED}${NC}"
    else
        echo -e "${YELLOW}  No active Industream stacks detected${NC}"
    fi

    if [ "$DRY_RUN" = "false" ]; then
        echo ""
        echo -e "${RED}  ⚠  This will remove ALL Industream resources from this machine.${NC}"
        if ! confirm "Proceed with full uninstall?"; then
            echo -e "${YELLOW}Aborted.${NC}"
            exit 0
        fi
    fi

    # Remove each detected environment
    for env in $DETECTED; do
        remove_environment "$env"
    done

    # Remove shared infrastructure
    remove_shared

    # Optionally remove local files
    if [ "$DELETE_DATA" = "true" ]; then
        remove_local_data
    fi
else
    echo -e "${BLUE}  Target: ${ENV^^} environment${NC}"

    if [ "$DRY_RUN" = "false" ]; then
        echo ""
        echo -e "${RED}  ⚠  This will remove the ${ENV^^} environment and its data.${NC}"
        if ! confirm "Proceed with uninstall of ${ENV}?"; then
            echo -e "${YELLOW}Aborted.${NC}"
            exit 0
        fi
    fi

    remove_environment "$ENV"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"
if [ "$DRY_RUN" = "true" ]; then
    echo -e "${BLUE}   Dry run complete - no changes were made${NC}"
else
    echo -e "${GREEN}   Uninstall complete${NC}"
fi
echo -e "${GREEN}══════════════════════════════════════════════════${NC}"

if [ "$DRY_RUN" = "false" ] && [ "$ALL" = "true" ] && [ "$DELETE_DATA" != "true" ]; then
    echo ""
    echo -e "${YELLOW}Note: Local files (secrets/, .env, certs/) were preserved.${NC}"
    echo -e "${YELLOW}To also remove them, re-run with --delete-data${NC}"
fi

echo ""
