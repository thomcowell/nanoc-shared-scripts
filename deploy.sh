#!/bin/bash
set -euo pipefail
# Setup environment, compile, and deploy to S3 + CloudFront
# Locally: checks/installs awscli, prompts for AWS auth if needed
# CI ($CI is set): skips local setup, uses environment credentials

# Resolve symlinks to find the real script directory
_s="${BASH_SOURCE[0]}"
while [[ -L "$_s" ]]; do _d="$(cd "$(dirname "$_s")" && pwd)"; _s="$(readlink "$_s")"; [[ "$_s" != /* ]] && _s="$_d/$_s"; done
source "$(cd "$(dirname "$_s")" && pwd)/lib/_shared.sh"
source "$(cd "$(dirname "$_s")" && pwd)/lib/deploy_helpers.sh"

if [[ ! -f "nanoc.yaml" ]]; then
    echo "Error: must be run from the project root (nanoc.yaml not found)"
    exit 1
fi

function check_for_awscli(){
    if ! command -v aws &> /dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew install awscli
            echo -e "${PASS} awscli installed"
        else
            command -v unzip &> /dev/null || pkg_install unzip unzip unzip unzip unzip
            local arch
            arch="$(uname -m)"
            local tmp_zip
            tmp_zip="$(mktemp -d)/awscliv2.zip"
            echo -e "${WARN} awscli not found, installing AWS CLI v2 for Linux (${arch})..."
            curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$tmp_zip"
            unzip -q "$tmp_zip" -d "$(dirname "$tmp_zip")"
            sudo_cmd
            ${SUDO} "$(dirname "$tmp_zip")/aws/install"
            if command -v aws &> /dev/null; then
                echo -e "${PASS} awscli installed"
            else
                echo -e "${FAIL} awscli install failed — install manually: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
                exit 4
            fi
        fi
    else
        echo -e "${PASS} awscli has been found"
    fi
}

function apply_staging_nanoc_config() {
    local config_file="$current_dir/nanoc.yaml"
    local staging_block
    staging_block=$(awk '/^staging:/{found=1; next} found && /^[^ ]/{exit} found' "$config_file")
    [[ -z "$staging_block" ]] && return 0

    local nanoc_overrides
    nanoc_overrides=$(echo "$staging_block" | grep -vE '^\s*(s3_bucket|cloudfront_distribution_id|aws_region|#):' | grep -v '^\s*$')
    [[ -z "$nanoc_overrides" ]] && return 0

    cp "$config_file" "${config_file}.pre-staging"
    while IFS= read -r line; do
        local key trimmed
        key=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
        trimmed=$(echo "$line" | sed 's/^  //')
        if grep -qE "^${key}:" "$config_file"; then
            sed -i.bak "s|^${key}:.*|${trimmed}|" "$config_file" && rm -f "${config_file}.bak"
            echo -e "${PASS} Staging override: ${trimmed}"
        else
            echo "" >> "$config_file"
            echo "$trimmed" >> "$config_file"
            echo -e "${PASS} Staging override (added): ${trimmed}"
        fi
    done <<< "$nanoc_overrides"
}

function restore_nanoc_config() {
    local config_file="$current_dir/nanoc.yaml"
    if [[ -f "${config_file}.pre-staging" ]]; then
        mv "${config_file}.pre-staging" "$config_file"
        echo -e "${PASS} Restored nanoc.yaml"
    fi
}

function check_aws_auth() {
    if [[ -n "${CI:-}" ]]; then
        # In CI, credentials are injected via environment — just validate they work
        if aws sts get-caller-identity &>/dev/null; then
            echo -e "${PASS} AWS authenticated"
            return
        else
            echo -e "${FAIL} AWS authentication failed. Check that AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_REGION secrets are set."
            exit 6
        fi
    fi
    # Local: check env vars, then fall back to interactive login
    # (use :- defaults — these are commonly unset entirely for devs who
    # authenticate via ~/.aws/credentials or SSO instead of env vars)
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        echo -e "${PASS} AWS credentials found in environment"
    fi
    if aws sts get-caller-identity &>/dev/null; then
        echo -e "${PASS} AWS authenticated"
        return
    fi
    echo -e "${WARN} Not authenticated — running aws login..."
    aws login --region $AWS_REGION
    if aws sts get-caller-identity &>/dev/null; then
        echo -e "${PASS} AWS authenticated"
    else
        echo -e "${FAIL} AWS authentication failed."
        echo -e "  Check your credentials or set ${WHITE}AWS_ACCESS_KEY_ID${NC} / ${WHITE}AWS_SECRET_ACCESS_KEY${NC} in your environment."
        exit 6
    fi
}

function generate_file_hashes() {
    local output_dir="${current_dir}/output"
    if [[ ! -d "$output_dir" ]]; then
        echo ""
        return
    fi
    find "$output_dir" -type f ! -name '.*' -print0 \
        | while IFS= read -r -d '' file; do sha256_file "$file"; done \
        | sed "s|  ${output_dir}/|  |" \
        | LC_ALL=C sort
}

function save_deployment_hashes() {
    local deployed_file="${current_dir}/.deployed"
    echo -e "${PASS} Saving file hashes to .deployed..."
    generate_file_hashes > "$deployed_file"
}

function update_hash_in_deployed() {
    local relative_path="$1"
    local deployed_file="${current_dir}/.deployed"
    local output_dir="${current_dir}/output"
    local new_hash
    new_hash=$(sha256_file "${output_dir}/${relative_path}" | cut -d' ' -f1)
    if [[ -f "$deployed_file" ]]; then
        grep -v "  ${relative_path}$" "$deployed_file" > "${deployed_file}.tmp"
        echo "${new_hash}  ${relative_path}" >> "${deployed_file}.tmp"
        LC_ALL=C sort "${deployed_file}.tmp" -o "${deployed_file}.tmp"
        mv "${deployed_file}.tmp" "$deployed_file"
    else
        echo "${new_hash}  ${relative_path}" > "$deployed_file"
    fi
}

function get_changed_files() {
    local deployed_file="${current_dir}/.deployed"
    local output_dir="${current_dir}/output"
    local temp_file current_hashes previous_hashes
    temp_file=$(mktemp)
    current_hashes=$(mktemp)
    previous_hashes=$(mktemp)
    trap 'rm -f "$temp_file" "$current_hashes" "$previous_hashes"' RETURN
    if [[ ! -f "$deployed_file" ]]; then
        echo -e "${WARN} No previous deployment found. All files will be uploaded." >&2
        find "$output_dir" -type f ! -name '.*' | sed "s|^$output_dir/||" | sort > "$temp_file"
        cat "$temp_file"
        return 0
    fi
    generate_file_hashes > "$current_hashes"
    LC_ALL=C sort "$deployed_file" > "$previous_hashes"
    comm -23 "$current_hashes" "$previous_hashes" | awk '{print $NF}' > "$temp_file"
    cat "$temp_file"
}

function get_deleted_files() {
    local deployed_file="${current_dir}/.deployed"
    local output_dir="${current_dir}/output"
    [[ ! -f "$deployed_file" ]] && return 0
    while IFS= read -r line; do
        local relative_path
        relative_path=$(echo "$line" | awk '{print $NF}')
        [[ ! -f "${output_dir}/${relative_path}" ]] && echo "$relative_path"
    done < "$deployed_file"
}

function remove_from_deployed() {
    local relative_path="$1"
    local deployed_file="${current_dir}/.deployed"
    [[ ! -f "$deployed_file" ]] && return 0
    grep -v "  ${relative_path}$" "$deployed_file" > "${deployed_file}.tmp"
    mv "${deployed_file}.tmp" "$deployed_file"
}

function delete_removed_files() {
    local s3_bucket="$1"
    local deleted_files
    deleted_files=$(get_deleted_files)
    [[ -z "$deleted_files" ]] && return 0
    local file_count
    file_count=$(echo "$deleted_files" | wc -l | tr -d ' ')
    echo -e "${WARN} Found ${file_count} file(s) removed from output — deleting from S3..." >&2
    echo "$deleted_files" | while read -r file; do
        if aws s3 rm "s3://${s3_bucket}/${file}" --quiet; then
            echo -e "${PASS} Deleted from S3: $file" >&2
            remove_from_deployed "$file"
            echo "$file"
        else
            echo -e "${FAIL} Failed to delete from S3: $file" >&2
        fi
    done
}

function deploy_with_hash_check() {
    local s3_bucket="$1"
    local output_dir="${current_dir}/output"
    local changed_files
    changed_files=$(get_changed_files)
    if [[ -z "$changed_files" ]]; then
        echo -e "${PASS} No files have changed since last deployment" >&2
        return 0
    fi
    local file_count
    file_count=$(echo "$changed_files" | wc -l | tr -d ' ')
    echo -e "${PASS} Found ${file_count} file(s) to deploy" >&2
    echo "$changed_files" | while read -r file; do
        if [[ -f "$output_dir/$file" ]]; then
            if aws s3 cp "$output_dir/$file" "s3://${s3_bucket}/${file}" --quiet; then
                echo -e "${PASS} Uploaded: $file" >&2
                update_hash_in_deployed "$file"
                echo "$file"
            else
                echo -e "${FAIL} Failed to upload: $file" >&2
            fi
        fi
    done
}

function commit_deployed_file() {
    local today
    today=$(date +%Y-%m-%d)
    git -C "$current_dir" add "${current_dir}/.deployed"
    git -C "$current_dir" commit -m "*** Release ${today} ***"
    echo -e "${PASS} Committed .deployed for release ${today}" >&2
}

function get_latest_release_tag() {
    local today
    today=$(date +%Y-%m-%d)
    git -C "$current_dir" tag -l "${today}-*" | sort -t'-' -k4 -n | tail -1
}

function create_release_tag() {
    local today
    today=$(date +%Y-%m-%d)
    local latest_tag
    latest_tag=$(get_latest_release_tag)
    local next_num
    if [[ -z "$latest_tag" ]]; then
        next_num="01"
    else
        local current_num="${latest_tag##*-}"
        next_num=$(printf "%02d" $((10#$current_num + 1)))
    fi
    local new_tag="${today}-${next_num}"
    git -C "$current_dir" tag "$new_tag"
    echo -e "${PASS} Tagged release: ${new_tag}" >&2
    git push
    git push --tags
    echo "$new_tag"
}

function print_help() {
    echo -e "Usage: ./deploy.sh [--deploy-only] [--staging] [-h|--help]

Wipes output/, compiles the site, and deploys to S3 + CloudFront.
Only uploads new/changed files (hash-based). Deletes removed files from S3.
Commits .deployed and creates a release tag on success.

Local:  checks/installs awscli, prompts for AWS auth if needed
CI:     skips local setup, uses AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars

Options:
  --deploy-only  Skip Ruby setup and nanoc compile — deploy output/ as-is
  --staging      Deploy to staging environment (reads staging config from nanoc.yaml,
                 uses s3 sync, skips hash tracking / .deployed commit / release tag)
  -h, --help     Show this help message"
}

# --- Main ---

DEPLOY_ONLY=false
STAGING=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy-only)
            DEPLOY_ONLY=true
            shift
            ;;
        --staging)
            STAGING=true
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

if [[ "$DEPLOY_ONLY" == false ]]; then
    rm -rf output/
    [[ "$STAGING" == true ]] && apply_staging_nanoc_config
    initiate
    bundle exec nanoc compile || { [[ "$STAGING" == true ]] && restore_nanoc_config; exit 1; }
    [[ "$STAGING" == true ]] && restore_nanoc_config
else
    if [[ ! -d "output" ]]; then
        echo -e "${FAIL} --deploy-only requires output/ to exist"
        exit 1
    fi
    echo -e "${PASS} --deploy-only: skipping compile, deploying output/ as-is"
fi

check_for_awscli
read_deploy_config
check_aws_auth

if [[ "$STAGING" == true ]]; then
    echo -e "${PASS} Deploying to s3://${S3_BUCKET}/ (staging — full sync)..."
    local exclude_args=""
    if [[ -n "${S3_SYNC_EXCLUDES:-}" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && exclude_args+=" --exclude ${pattern}"
        done <<< "$S3_SYNC_EXCLUDES"
    fi
    aws s3 sync "${current_dir}/output/" "s3://${S3_BUCKET}/" --delete $exclude_args
    echo -e "${PASS} Invalidating all paths on CloudFront distribution ${CF_DIST_ID}..."
    aws cloudfront create-invalidation \
        --distribution-id "$CF_DIST_ID" \
        --invalidation-batch "{\"Paths\":{\"Quantity\":1,\"Items\":[\"/*\"]},\"CallerReference\":\"$(date +%s)\"}" \
        --no-cli-pager
    echo -e "${PASS} Staging deploy complete"
else
    echo -e "${PASS} Deploying to s3://${S3_BUCKET}/ (hash-based)..."
    CHANGED_FILES=$(deploy_with_hash_check "$S3_BUCKET")
    DELETED_FILES=$(delete_removed_files "$S3_BUCKET")
    ALL_AFFECTED=$(printf '%s\n' $CHANGED_FILES $DELETED_FILES | grep -v '^$')

    if [[ -n "$ALL_AFFECTED" ]]; then
        echo -e "${PASS} Invalidating affected files on CloudFront distribution ${CF_DIST_ID}..."
        CF_QUANTITY=$(echo "$ALL_AFFECTED" | wc -l | tr -d ' ')
        CF_ITEMS=$(echo "$ALL_AFFECTED" | sed 's|^|"/|' | sed 's|$|"|' | tr '\n' ',' | sed 's/,$//')
        aws cloudfront create-invalidation \
            --distribution-id "$CF_DIST_ID" \
            --invalidation-batch "{\"Paths\":{\"Quantity\":${CF_QUANTITY},\"Items\":[${CF_ITEMS}]},\"CallerReference\":\"$(date +%s)\"}" \
            --no-cli-pager
        save_deployment_hashes
        commit_deployed_file
        create_release_tag
    else
        echo -e "${PASS} No files changed — nothing to deploy"
        save_deployment_hashes
    fi
fi
