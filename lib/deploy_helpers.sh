#!/bin/bash
# Common deployment helper functions for deploy.sh, fix-content-type.sh, and other deployment scripts

function read_deploy_config() {
    local config_file="$current_dir/nanoc.yaml"
    local env_label="production"
    local block_name="production"
    if [[ "${STAGING:-false}" == true ]]; then
        env_label="staging"
        block_name="staging"
    fi

    local env_block
    env_block=$(awk "/^${block_name}:/{found=1; next} found && /^[^ ]/{exit} found" "$config_file")

    if [[ -n "$env_block" ]]; then
        S3_BUCKET=$(echo "$env_block" | grep 's3_bucket:' | awk '{print $2}' | tr -d '"')
        CF_DIST_ID=$(echo "$env_block" | grep 'cloudfront_distribution_id:' | awk '{print $2}' | tr -d '"')
        AWS_REGION=$(echo "$env_block" | grep 'aws_region:' | awk '{print $2}' | tr -d '"')
    elif [[ "${STAGING:-false}" == true ]]; then
        echo -e "${FAIL} No staging: block found in nanoc.yaml"
        exit 5
    else
        S3_BUCKET=$(grep -E '^s3_bucket:' "$config_file" | awk '{print $2}' | tr -d '"')
        CF_DIST_ID=$(grep -E '^cloudfront_distribution_id:' "$config_file" | awk '{print $2}' | tr -d '"')
        AWS_REGION=$(grep -E '^aws_region:' "$config_file" | awk '{print $2}' | tr -d '"')
    fi

    if [[ -z "$S3_BUCKET" ]]; then
        echo -e "${FAIL} s3_bucket not set in nanoc.yaml (under ${block_name}:)"
        exit 5
    fi
    if [[ -z "$CF_DIST_ID" || "$CF_DIST_ID" == "<DISTRIBUTION_ID>" ]]; then
        echo -e "${FAIL} cloudfront_distribution_id not set in nanoc.yaml (under ${block_name}:) — please replace <DISTRIBUTION_ID>"
        exit 5
    fi
    S3_SYNC_EXCLUDES=""
    local exclude_block
    exclude_block=$(awk "/^${block_name}:/{found=1; next} found && /^[^ ]/{exit} found" "$config_file" \
        | awk '/s3_sync_exclude:/{found=1; next} found && /^    -/{print; next} found{exit}')
    if [[ -n "$exclude_block" ]]; then
        S3_SYNC_EXCLUDES=$(echo "$exclude_block" | sed 's/^[[:space:]]*- *//' | tr -d '"')
    fi

    echo -e "${PASS} [${env_label}] ${AWS_REGION} Deploy target: s3://${S3_BUCKET}  CF: ${CF_DIST_ID}"
}

function set_s3_content_type() {
    local s3_bucket="$1"
    local s3_key="$2"
    local content_type="$3"

    if aws s3 cp "s3://${s3_bucket}/${s3_key}" "s3://${s3_bucket}/${s3_key}" \
        --content-type "$content_type" \
        --metadata-directive REPLACE \
        --region "$AWS_REGION" --quiet; then
        echo -e "${PASS} Set Content-Type=${content_type} for ${s3_key}" >&2
    else
        echo -e "${FAIL} Failed to set Content-Type=${content_type} for ${s3_key}" >&2
        return 1
    fi
}
