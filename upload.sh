#!/usr/bin/env bash
#====================================================================================================
#
# Function: Upload files to GitHub Releases via the GitHub REST API
# Copyright (C) 2026- https://github.com/ophub/upload-to-releases
#
# Refer to the GitHub REST API official documentation:
# https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28
# https://docs.github.com/en/rest/releases/assets?apiVersion=2022-11-28
#
#========================================== Functions list ==========================================
#
# error_msg                : Output error message and exit
# cleanup                  : Remove all temporary state files on script exit
#
# url_encode               : Percent-encode a string for use in a URL query parameter
# format_size              : Convert byte count to a human-readable string (KiB/MiB/GiB)
# sanitize_log             : Strip workflow command prefixes (::) from user-controlled strings
# api_call                 : Execute a GitHub REST API request with retry on transient errors
#
# install_dependencies     : Check for required commands and install missing dependencies if possible
# init_var                 : Initialize, validate, and print all parameters (reads INPUT_* env vars)
#
# get_release              : Query existing release metadata by tag name
# build_release_payload    : Assemble a JSON body for the releases create/update endpoint
# create_release           : Create a new release via the API
# update_release           : Update an existing release via the API
# error_release_permission : Print HTTP 422 permission-error guidance and abort
# ensure_release           : Guarantee the target release exists (create or update as needed)
#
# expand_artifacts         : Expand glob/comma patterns into a resolved, deduplicated file list
# fetch_assets_list        : Retrieve all existing asset records for the release (paginated)
# delete_asset             : Delete a single release asset by its ID
# remove_all_assets        : Delete every existing asset from the release (bulk pre-upload clear)
# upload_asset             : Upload one file as a release asset with retry + duplicate handling
# cleanup_partial_upload   : Remove a stale partial-upload asset before a retry
# upload_all_assets        : Iterate the resolved file list and upload each asset in sequence
# verify_uploads           : SHA-256 integrity check — compare local files vs uploaded assets
#
# set_action_outputs       : Write release metadata and asset map to GITHUB_OUTPUT
#
#==================================== Set environment variables =====================================
#
# Default parameter values
# Target repository in <owner>/<repo> format; defaults to the repository running the workflow
repo=""
# Tag name of the release to create or update
tag=""
# File path(s) to upload; supports glob patterns and comma-separated values
artifacts=""
# Update release metadata if a release for the given tag already exists (true/false)
allow_updates="true"
# Remove all existing assets from the release before uploading new ones (true/false)
remove_artifacts="false"
# Replace an existing asset that has the same filename (true/false)
replaces_artifacts="true"
# Mark this release as the latest release (true/false/legacy)
make_latest="true"
# Mark this release as a pre-release (true/false)
prerelease="false"
# Mark this release as a draft (true/false)
draft="false"
# Display title of the release; falls back to the tag name when empty
release_name=""
# Markdown body text of the release
body=""
# Path to a Markdown file used as the release body; takes precedence over body
body_file=""
# Output detailed JSON logs for each step (true/false)
out_log="false"
# per-file upload timeout, minutes (0 = disables max-time only; stall guard still active)
upload_timeout="5"

# UPLOAD_MAX_TIME is derived from upload_timeout at runtime (seconds; 0 = unlimited)
UPLOAD_MAX_TIME=$((upload_timeout * 60))
# Abort an upload if speed stays below UPLOAD_SPEED_LIMIT bytes/s for UPLOAD_SPEED_TIME seconds
UPLOAD_SPEED_LIMIT="1024"
# Seconds at speed below UPLOAD_SPEED_LIMIT before curl aborts the transfer
UPLOAD_SPEED_TIME="60"

# Maximum upload attempts per file (initial try + retries)
RETRY_MAX_ATTEMPTS="3"
# Initial back-off between upload retries (seconds); doubled on each subsequent attempt
RETRY_WAIT_INIT="30"
# Seconds to wait after receiving HTTP 429 (rate-limited) before the next attempt
RATE_LIMIT_WAIT="60"

# curl connection / transfer timeout settings for regular API calls (not file uploads)
CURL_CONNECT_TIMEOUT="30"
# bytes/s minimum speed threshold for stall detection
CURL_SPEED_LIMIT="1"
# seconds below CURL_SPEED_LIMIT before the connection is aborted
CURL_SPEED_TIME="60"
# GitHub API pagination limit
GITHUB_PER_PAGE="100"

# Output color labels
STEPS="[\033[95m STEPS \033[0m]"
INFO="[\033[94m INFO \033[0m]"
NOTE="[\033[93m NOTE \033[0m]"
WARN="[\033[91m WARN \033[0m]"
ERROR="[\033[91m ERROR \033[0m]"
SUCCESS="[\033[92m SUCCESS \033[0m]"
# Semantic labels for upload progress messages
FILE="[\033[94m FILE \033[0m]" # upload start   (┌─)  — same blue as INFO
SIZE="[\033[94m SIZE \033[0m]" # size/MIME line (│ )  — same blue as INFO
DONE="[\033[92m DONE \033[0m]" # upload done    (└─)  — same green as SUCCESS
#
#====================================================================================================

# Print a red error message and immediately abort the script with exit code 1.
error_msg() {
    echo -e "${ERROR} ${1}"
    exit 1
}

# Called automatically by "trap cleanup EXIT"; removes PID-named temp files on any exit.
cleanup() {
    rm -f "${ASSETS_LIST_FILE}"
    rm -f "${UPLOAD_RESULTS_FILE}"
}

# url_encode <string>
# Percent-encode a string so it is safe to embed in a URL query parameter.
url_encode() {
    local raw="${1}"
    local encoded="" i char hex
    for ((i = 0; i < ${#raw}; i++)); do
        char="${raw:i:1}"
        case "${char}" in
        # RFC 3986 unreserved characters pass through unchanged
        [A-Za-z0-9_.~-]) encoded+="${char}" ;;
        # Everything else is %-encoded as uppercase hex
        *)
            printf -v hex '%%%02X' "'${char}"
            encoded+="${hex}"
            ;;
        esac
    done
    printf '%s' "${encoded}"
}

# format_size <bytes>
# Print a human-readable file size string.
format_size() {
    local bytes="${1}"

    # Choose the largest unit where the value is >= 1 to keep the number readable
    if [[ "${bytes}" -ge 1073741824 ]]; then
        awk "BEGIN{printf \"%.2f GiB\", ${bytes}/1073741824}"
    elif [[ "${bytes}" -ge 1048576 ]]; then
        awk "BEGIN{printf \"%.2f MiB\", ${bytes}/1048576}"
    elif [[ "${bytes}" -ge 1024 ]]; then
        awk "BEGIN{printf \"%.2f KiB\", ${bytes}/1024}"
    else
        printf "%d B" "${bytes}"
    fi
}

# sanitize_log <string>
# Strips GitHub Actions workflow command prefixes (::error::, ::warning::, etc.)
# from user-controlled strings before echoing them to stdout. This prevents
# log injection attacks where a malicious tag name, filename, or repo name
# could inject workflow commands like ::error:: or ::add-mask::.
# Reference: https://docs.github.com/en/actions/reference/security/secure-use
sanitize_log() {
    local input="${1}"
    # Replace :: with a harmless visual marker to neutralise workflow commands
    printf '%s' "${input//::/⁘⁘}"
}

# api_call <body_var> <code_var> <method> <url> [extra curl args...]
# Executes a GitHub API request with automatic retry on transient errors.
#
# Results are written to the caller's variables via nameref (declare -n):
#   <body_var>  – the response body (JSON string)
#   <code_var>  – the HTTP status code returned by the server
#
# Both variables are reset to empty at the start of each call to prevent
# stale data from a previous invocation leaking into the caller.
#
# Retry policy:
#   • 401 / 403 / 404  → fail immediately (non-retryable auth / not-found errors)
#   • 429              → wait RATE_LIMIT_WAIT seconds then retry (up to 3 times)
#   • any other non-2xx → exponential back-off, up to 3 attempts
api_call() {
    # nameref parameters — write results directly into the caller's variables
    local -n ref_body="${1}"
    local -n ref_code="${2}"
    shift 2

    local method="${1}" url="${2}"
    # remaining args are passed through to curl as extra flags/headers
    shift 2

    # Reset output variables to prevent stale data from a previous call
    ref_body=""
    ref_code=""

    # counters and timers for retry logic
    local attempt=0 max_attempts="${RETRY_MAX_ATTEMPTS}"
    # back-off starts at RETRY_WAIT_INIT, doubles each round
    local wait_time="${RETRY_WAIT_INIT}"
    # temp file to capture the response body separately from the status code
    local tmp_body
    # per-attempt locals — only committed to the nameref on return
    local status_code resp_body

    # Loop until we hit max attempts
    while [[ "${attempt}" -lt "${max_attempts}" ]]; do
        attempt=$((attempt + 1))
        tmp_body="$(mktemp)" # fresh temp file for each attempt to avoid stale data

        # Send the request; -w '%{http_code}' writes only the status code to stdout;
        # the body goes to tmp_body via -o so both values can be captured independently
        status_code=$(
            curl -sL \
                --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
                --speed-limit "${CURL_SPEED_LIMIT}" \
                --speed-time "${CURL_SPEED_TIME}" \
                -o "${tmp_body}" -w '%{http_code}' \
                -X "${method}" \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer ${gh_token}" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "${@}" \
                "${url}" 2>/dev/null
        )
        local curl_exit="${?}"
        # read body before deleting temp file to ensure we capture the response even if curl fails
        resp_body="$(cat "${tmp_body}" 2>/dev/null)"
        rm -f "${tmp_body}"

        # curl failed at the transport level (DNS, TLS, timeout, etc.) — not an HTTP error
        if [[ "${curl_exit}" -ne 0 ]]; then
            echo -e "${NOTE} (api_call) curl error code ${curl_exit} on attempt ${attempt}/${max_attempts} [${method} ${url}]"
            if [[ "${attempt}" -lt "${max_attempts}" ]]; then
                echo -e "${NOTE} (api_call) Retrying in ${wait_time}s..."
                sleep "${wait_time}"
                # exponential back-off for transport-level errors (not HTTP status codes)
                wait_time=$((wait_time * 2))
                continue
            fi
            # Final failure: commit last-attempt values so caller can inspect them
            ref_body="${resp_body}"
            ref_code="${status_code}"
            return 1
        fi

        # Non-retryable auth / not-found errors — let caller interpret the response
        if [[ "${status_code}" =~ ^(401|403|404)$ ]]; then
            ref_body="${resp_body}"
            ref_code="${status_code}"
            return 0
        fi

        # 2xx = success; return immediately
        if [[ "${status_code}" =~ ^2 ]]; then
            ref_body="${resp_body}"
            ref_code="${status_code}"
            return 0
        fi

        # 429 = rate limited; pause for the full RATE_LIMIT_WAIT period before retrying.
        # attempt is already incremented at the top of the loop, so this still counts
        # toward max_attempts — prevents an infinite loop if the server never stops rate-limiting.
        if [[ "${status_code}" == "429" ]]; then
            echo -e "${NOTE} (api_call) Rate limited (HTTP 429) on attempt ${attempt}/${max_attempts}, waiting ${RATE_LIMIT_WAIT}s..."
            sleep "${RATE_LIMIT_WAIT}"
            continue
        fi

        # Other server-side or transient errors (5xx, etc.) — back-off and retry
        local api_error
        api_error="$(echo "${resp_body}" | jq -r '.message // "Unknown error"' 2>/dev/null)"
        echo -e "${NOTE} (api_call) HTTP ${status_code} on attempt ${attempt}/${max_attempts}: ${api_error}"
        if [[ "${attempt}" -lt "${max_attempts}" ]]; then
            echo -e "${NOTE} (api_call) Retrying in ${wait_time}s..."
            sleep "${wait_time}"
            wait_time=$((wait_time * 2))
        fi
    done

    # Exhausted all retries — commit last-attempt values so caller can inspect them
    ref_body="${resp_body}"
    ref_code="${status_code}"
    return 0
}

install_dependencies() {
    echo -e "${STEPS} Installing missing dependencies..."

    # ── Dependency check ──────────────────────────────────────────────────
    # Required tools: jq (JSON), curl (HTTP), sha256sum / shasum
    # (integrity verification), file (MIME detection).
    # All are pre-installed on GitHub-hosted ubuntu-* runners; the block below
    # is a safety net for self-hosted runners or minimal container images.
    local dependency_packages=("jq" "curl" "file")
    local missing_pkgs=()

    # Check if each required command is available; if not, add its package to the missing_pkgs list
    for pkg in "${dependency_packages[@]}"; do
        if ! command -v "${pkg}" >/dev/null 2>&1; then
            missing_pkgs+=("${pkg}")
        fi
    done

    # sha256sum is part of coreutils (Linux); shasum -a 256 is the macOS equivalent
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        missing_pkgs+=("coreutils")
    fi

    # Install any missing packages using the first available package manager
    [[ "${#missing_pkgs[@]}" -gt 0 ]] && {
        echo -e "${NOTE} Missing dependencies detected: [ ${missing_pkgs[*]} ]"
        sudo apt-get -qq update && sudo apt-get -qq install -y "${missing_pkgs[@]}" || true
    }

    # Resolve the SHA-256 command after potential install; set SHA256_CMD for later use
    if command -v sha256sum >/dev/null 2>&1; then
        SHA256_CMD="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        SHA256_CMD="shasum -a 256"
    else
        error_msg "sha256sum / shasum is required but could not be installed."
    fi
}

init_var() {
    echo -e "${STEPS} Initializing parameters..."

    # ── Read inputs from INPUT_* environment variables ────────────────────
    # All inputs are injected by action.yml as INPUT_* env vars.
    # GH_TOKEN is kept separate and never exposed in INPUT_* to avoid leaking
    # the token value into the process list or shell history.
    gh_token="${GH_TOKEN:-}"

    # Mask the token in all GitHub Actions log output to prevent accidental exposure.
    # Any subsequent echo/printf that contains this value will be redacted as "***".
    [[ -n "${gh_token}" ]] && echo "::add-mask::${gh_token}"

    repo="${INPUT_REPO:-}"
    tag="${INPUT_TAG:-}"
    artifacts="${INPUT_ARTIFACTS:-}"
    allow_updates="${INPUT_ALLOW_UPDATES:-true}"
    remove_artifacts="${INPUT_REMOVE_ARTIFACTS:-false}"
    replaces_artifacts="${INPUT_REPLACES_ARTIFACTS:-true}"
    upload_timeout="${INPUT_UPLOAD_TIMEOUT:-5}"
    make_latest="${INPUT_MAKE_LATEST:-true}"
    prerelease="${INPUT_PRERELEASE:-false}"
    draft="${INPUT_DRAFT:-false}"
    release_name="${INPUT_NAME:-}"
    body="${INPUT_BODY:-}"
    body_file="${INPUT_BODY_FILE:-}"
    out_log="${INPUT_OUT_LOG:-false}"

    # ── Validate required parameters ─────────────────────────────────────
    [[ -z "${gh_token}" ]] && error_msg "[ gh_token ] is required (set via the GH_TOKEN environment variable)."
    [[ -z "${repo}" ]] && error_msg "[ repo ] is required."
    [[ -z "${tag}" ]] && error_msg "[ tag ] is required."
    [[ -z "${artifacts}" ]] && error_msg "[ artifacts ] is required."

    # ── Validate boolean / enum inputs ───────────────────────────────────
    # Guards standalone invocation of upload.sh outside action.yml where
    # action.yml's own validate_boolean block is not executed.
    local bool_pair bool_name bool_value
    for bool_pair in \
        "allow_updates:${allow_updates}" \
        "remove_artifacts:${remove_artifacts}" \
        "replaces_artifacts:${replaces_artifacts}" \
        "prerelease:${prerelease}" \
        "draft:${draft}" \
        "out_log:${out_log}"; do
        bool_name="${bool_pair%%:*}"
        bool_value="${bool_pair#*:}"
        [[ ! "${bool_value}" =~ ^(true|false)$ ]] &&
            error_msg "Invalid value for ${bool_name}: '${bool_value}' must be 'true' or 'false'."
    done
    [[ ! "${make_latest}" =~ ^(true|false|legacy)$ ]] &&
        error_msg "Invalid value for make_latest: '${make_latest}' must be 'true', 'false', or 'legacy'."

    # ── Validate upload_timeout (must be a non-negative integer) ─────────
    if [[ ! "${upload_timeout}" =~ ^[0-9]+$ ]]; then
        error_msg "Invalid value for upload_timeout: '${upload_timeout}' — must be a non-negative integer (minutes)."
    fi
    # Convert minutes → seconds; curl's --max-time=0 means unlimited
    UPLOAD_MAX_TIME=$((upload_timeout * 60))

    # ── Load release body from file if provided (takes precedence over body) ──
    if [[ -n "${body_file}" ]]; then
        [[ ! -f "${body_file}" ]] && error_msg "body_file not found: [ ${body_file} ]"
        body="$(cat "${body_file}")"
        echo -e "${INFO} Loaded release body from file: [ ${body_file} ]"
    fi

    # Fall back to the tag name when no release display name is provided
    [[ -z "${release_name}" ]] && release_name="${tag}"

    # ── Print resolved parameters ─────────────────────────────────────────
    # Show timeout as "unlimited" or "N min (Ns)" for clarity
    local timeout_display
    if [[ "${upload_timeout}" -eq 0 ]]; then
        timeout_display="unlimited"
    else
        timeout_display="${upload_timeout} min (${UPLOAD_MAX_TIME}s)"
    fi

    echo -e "${INFO} repo:               [ $(sanitize_log "${repo}") ]"
    echo -e "${INFO} tag:                [ $(sanitize_log "${tag}") ]"
    echo -e "${INFO} artifacts:          [ $(sanitize_log "${artifacts}") ]"
    echo -e "${INFO} allow_updates:      [ ${allow_updates} ]"
    echo -e "${INFO} remove_artifacts:   [ ${remove_artifacts} ]"
    echo -e "${INFO} replaces_artifacts: [ ${replaces_artifacts} ]"
    echo -e "${INFO} upload_timeout:     [ ${timeout_display} ]"
    echo -e "${INFO} make_latest:        [ ${make_latest} ]"
    echo -e "${INFO} prerelease:         [ ${prerelease} ]"
    echo -e "${INFO} draft:              [ ${draft} ]"
    echo -e "${INFO} release_name:       [ $(sanitize_log "${release_name}") ]"
    echo -e "${INFO} out_log:            [ ${out_log} ]"
    echo -e ""
}

# Queries the GitHub API for an existing release matching the configured tag.
# Sets globals: release_id, upload_url, html_url (empty strings if not found).
get_release() {
    echo -e "${STEPS} Querying release info for tag [ $(sanitize_log "${tag}") ]..."

    # Reset globals so callers can distinguish "not found" from "not yet queried"
    release_id=""
    upload_url=""
    html_url=""

    local resp code
    api_call resp code GET "${GITHUB_API_URL:-https://api.github.com}/repos/${repo}/releases/tags/${tag}"

    if [[ "${code}" == "200" ]]; then
        release_id="$(echo "${resp}" | jq -r '.id')"
        # The upload_url from the API contains an RFC 6570 template suffix — strip it for plain curl use
        upload_url="$(echo "${resp}" | jq -r '.upload_url' | sed 's/{?name,label}$//')"
        html_url="$(echo "${resp}" | jq -r '.html_url')"
        echo -e "${INFO} Found existing release: id=[ ${release_id} ], url=[ ${html_url} ]"
        [[ "${out_log}" == "true" ]] && echo -e "${INFO} Full release response:\n${resp}"
    elif [[ "${code}" == "404" ]]; then
        # 404 is the normal "not found" response — not an error
        echo -e "${INFO} No existing release found for tag [ $(sanitize_log "${tag}") ]."
    elif [[ "${code}" == "403" ]]; then
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Forbidden"' 2>/dev/null)"
        error_release_permission "query" "${code}" "${api_error}"
    else
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Unknown error"' 2>/dev/null)"
        error_msg "Failed to query release (HTTP ${code}): ${api_error}"
    fi
}

# error_release_permission <operation> <http_code> <api_error>
# Print a standardised permission-error message for HTTP 403/422 on release create/update,
# then abort the script. Centralised here so the guidance text is maintained in one place.
error_release_permission() {
    local operation="${1}" http_code="${2}" api_error="${3}"
    echo -e "${ERROR} ❌ Failed to [ ${operation} ] release (HTTP ${http_code}): ${api_error}"
    echo -e "${NOTE} ⚠️ This is usually a permissions issue. Please enable write access for the GITHUB_TOKEN:"
    echo -e "${NOTE} ✅ Repository → Settings → Actions → General → Workflow permissions → Select \"Read and write permissions\" → Save"
    echo -e "${NOTE} ✅ Or add [ permissions: contents: write ] to your workflow YAML."
    error_msg "Release ${operation} failed due to insufficient permissions (HTTP ${http_code})."
}

# build_release_payload <tag_name> <name> <body> <draft_bool> <prerelease_bool> <make_latest>
# Outputs a compact JSON payload suitable for the releases create/update API.
# Uses jq --argjson for boolean fields to avoid string/bool type confusion.
build_release_payload() {
    local tag_name="${1}" name="${2}" body="${3}"
    local draft_val="${4}" prerelease_val="${5}" make_latest_val="${6}"

    # Using jq to construct the JSON ensures proper escaping and formatting, especially for multiline bodies.
    jq -n \
        --arg tag_name "${tag_name}" \
        --arg name "${name}" \
        --arg body "${body}" \
        --argjson draft "${draft_val}" \
        --argjson prerelease "${prerelease_val}" \
        --arg make_latest "${make_latest_val}" \
        '{
            tag_name:    $tag_name,
            name:        $name,
            body:        $body,
            draft:       $draft,
            prerelease:  $prerelease,
            make_latest: $make_latest
        }'
}

# Creates a brand-new release for the configured tag via POST.
# Populates globals: release_id, upload_url, html_url.
create_release() {
    echo -e "${STEPS} Creating new release for tag [ $(sanitize_log "${tag}") ]..."

    # Convert shell "true"/"false" strings to bare JSON booleans for the API payload
    local draft_val prerelease_val
    draft_val="$([[ "${draft}" == "true" ]] && echo "true" || echo "false")"
    prerelease_val="$([[ "${prerelease}" == "true" ]] && echo "true" || echo "false")"

    # Build the JSON payload for the release creation API call
    local payload
    payload="$(build_release_payload "${tag}" "${release_name}" "${body}" \
        "${draft_val}" "${prerelease_val}" "${make_latest}")"

    [[ "${out_log}" == "true" ]] && echo -e "${INFO} Create release payload:\n${payload}"

    # POST to the releases endpoint to create a new release; the response includes the new release ID and upload URL
    local resp code
    api_call resp code POST "${GITHUB_API_URL:-https://api.github.com}/repos/${repo}/releases" \
        -H "Content-Type: application/json" \
        -d "${payload}"

    # 201 Created on success (200 accepted as well for resilience)
    if [[ "${code}" =~ ^(200|201)$ ]]; then
        release_id="$(echo "${resp}" | jq -r '.id')"
        # Strip RFC 6570 template suffix from upload_url (same as in get_release)
        upload_url="$(echo "${resp}" | jq -r '.upload_url' | sed 's/{?name,label}$//')"
        html_url="$(echo "${resp}" | jq -r '.html_url')"
        echo -e "${SUCCESS} Release created: id=[ ${release_id} ], url=[ ${html_url} ]"
    elif [[ "${code}" == "403" ]]; then
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Forbidden"' 2>/dev/null)"
        error_release_permission "create" "${code}" "${api_error}"
    elif [[ "${code}" == "422" ]]; then
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Validation Failed"' 2>/dev/null)"
        error_release_permission "create" "${code}" "${api_error}"
    else
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Unknown error"' 2>/dev/null)"
        error_msg "Failed to create release (HTTP ${code}): ${api_error}"
    fi
}

# Updates metadata (name, body, flags) of the already-existing release via PATCH.
# Refreshes globals: upload_url, html_url.
update_release() {
    echo -e "${STEPS} Updating release [ ${release_id} ] for tag [ $(sanitize_log "${tag}") ]..."

    # Convert shell "true"/"false" strings to bare JSON booleans for the API payload
    local draft_val prerelease_val
    draft_val="$([[ "${draft}" == "true" ]] && echo "true" || echo "false")"
    prerelease_val="$([[ "${prerelease}" == "true" ]] && echo "true" || echo "false")"

    # Build the JSON payload for the release update API call
    local payload
    payload="$(build_release_payload "${tag}" "${release_name}" "${body}" \
        "${draft_val}" "${prerelease_val}" "${make_latest}")"

    [[ "${out_log}" == "true" ]] && echo -e "${INFO} Update release payload:\n${payload}"

    # PATCH sends a full payload to the release ID endpoint; GitHub applies all provided fields
    local resp code
    api_call resp code PATCH "${GITHUB_API_URL:-https://api.github.com}/repos/${repo}/releases/${release_id}" \
        -H "Content-Type: application/json" \
        -d "${payload}"

    # 200 OK on success (201 accepted as well for resilience)
    if [[ "${code}" =~ ^(200|201)$ ]]; then
        upload_url="$(echo "${resp}" | jq -r '.upload_url' | sed 's/{?name,label}$//')"
        html_url="$(echo "${resp}" | jq -r '.html_url')"
        echo -e "${SUCCESS} Release updated: id=[ ${release_id} ], url=[ ${html_url} ]"
    elif [[ "${code}" == "403" ]]; then
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Forbidden"' 2>/dev/null)"
        error_release_permission "update" "${code}" "${api_error}"
    elif [[ "${code}" == "422" ]]; then
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Validation Failed"' 2>/dev/null)"
        error_release_permission "update" "${code}" "${api_error}"
    else
        local api_error
        api_error="$(echo "${resp}" | jq -r '.message // "Unknown error"' 2>/dev/null)"
        error_msg "Failed to update release (HTTP ${code}): ${api_error}"
    fi
}

# Entry point for release setup: queries, then creates or updates based on configuration.
# After this function returns, release_id and upload_url are guaranteed to be set.
ensure_release() {
    get_release

    if [[ -n "${release_id}" ]]; then
        # Release already exists — update metadata only when allow_updates permits
        if [[ "${allow_updates}" == "true" ]]; then
            update_release
        else
            echo -e "${NOTE} Release already exists and allow_updates=false; metadata update skipped."
        fi
    else
        # No existing release — create one from scratch
        create_release
    fi

    # upload_url is mandatory; abort if something went wrong in create/update
    [[ -z "${upload_url}" ]] && error_msg "Could not obtain a valid upload URL for the release."

    echo -e ""
}

# Parses the comma-separated artifact patterns, expands globs, deduplicates,
# and populates the global resolved_files array.
# Prints a numbered file manifest with sizes before returning.
expand_artifacts() {
    echo -e "${STEPS} Expanding artifact patterns..."

    # final list of absolute / relative file paths to upload
    resolved_files=()
    # tracks already-added paths for O(1) deduplication using associative array
    declare -A seen_files
    # files skipped due to exceeding the GitHub 2GB asset limit (for summary reporting)
    local oversized_files=()
    local fsz

    # Split the comma-separated artifact string into individual pattern entries
    IFS=',' read -r -a artifact_entries <<<"${artifacts}"

    for entry in "${artifact_entries[@]}"; do
        # Strip leading/trailing whitespace from each pattern entry
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "${entry}" ]] && continue

        # Expand the glob pattern; nullglob ensures an empty array on no match
        shopt -s nullglob
        local matched=(${entry})
        shopt -u nullglob

        if [[ "${#matched[@]}" -eq 0 ]]; then
            echo -e "${NOTE} Pattern matched no files: [ $(sanitize_log "${entry}") ]"
            continue
        fi

        # Process each matched path: skip non-regular files and deduplicate against previously seen paths
        for f in "${matched[@]}"; do
            # Skip directories, symlinks, and other non-regular file types
            if [[ ! -f "${f}" ]]; then
                echo -e "${NOTE} Skipping non-regular file: [ ${f} ]"
                continue
            fi

            # Deduplicate: skip this path if it was already added by an earlier pattern (O(1) lookup)
            if [[ -n "${seen_files[${f}]+x}" ]]; then
                echo -e "${NOTE} Duplicate skipped: [ ${f} ]"
                continue
            fi

            # GitHub Release assets have a maximum size of 2 GiB — the server
            # rejects files exceeding this limit with HTTP 413. Pre-check here
            # to avoid wasting time on uploads, timeouts, and retries that will
            # never succeed.
            fsz="$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null || echo "0")"
            if [[ "${fsz}" -gt 2147483648 ]]; then
                oversized_files+=("${f}")
                seen_files["${f}"]=1
                continue
            fi

            seen_files["${f}"]=1
            resolved_files+=("${f}")
        done
    done

    # ── Print numbered file manifest (only when there are files to upload) ──
    # Shows index, filename, and size so the upload queue is visible upfront
    local total="${#resolved_files[@]}"
    if [[ "${total}" -gt 0 ]]; then
        echo -e "${INFO} Total files to upload: [ ${total} ]"
        echo -e "${INFO} ────────────────────────────────────────────────────────────────────────"
        local i=0
        local total_bytes=0
        for f in "${resolved_files[@]}"; do
            i=$((i + 1))
            # stat -c (GNU/Linux) and stat -f (macOS) use different format flags
            fsz="$(stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null || echo "0")"

            total_bytes=$((total_bytes + fsz))
            printf "%b  %3d/%-3d  %10s   %s\n" \
                "${INFO}" "${i}" "${total}" "$(format_size "${fsz}")" "$(basename "${f}")"
        done
        echo -e "${INFO} ────────────────────────────────────────────────────────────────────────"
        echo -e "${INFO} Total: [ ${total} ] files,  $(format_size "${total_bytes}")"
    fi

    # Print oversized files summary if any (formatted like skipped_files list)
    if [[ "${#oversized_files[@]}" -gt 0 ]]; then
        local os_total="${#oversized_files[@]}"
        local os_idx=0
        local max_osname_len=0
        local osn osn_padded osz
        for os_path in "${oversized_files[@]}"; do
            osn="$(basename "${os_path}")"
            [[ "${#osn}" -gt "${max_osname_len}" ]] && max_osname_len="${#osn}"
        done
        for os_path in "${oversized_files[@]}"; do
            os_idx=$((os_idx + 1))
            osn="$(basename "${os_path}")"
            printf -v osn_padded "%-${max_osname_len}s" "${osn}"
            osz="$(stat -c '%s' "${os_path}" 2>/dev/null || stat -f '%z' "${os_path}" 2>/dev/null || echo "0")"
            echo -e "${WARN} OVERSIZE ${os_idx}/${os_total} [ ${osn_padded} ]  [ size: $(format_size "${osz}") ]"
        done
    fi

    echo -e "${INFO} ────────────────────────────────────────────────────────────────────────"
    echo -e ""

    # Abort early if no files were resolved — nothing to upload
    if [[ "${total}" -eq 0 ]]; then
        if [[ "${#oversized_files[@]}" -gt 0 ]]; then
            error_msg "All [ ${#oversized_files[@]} ] matched file(s) exceed the GitHub 2GB limit. Nothing to upload."
        else
            error_msg "No files matched the provided artifact patterns: [ ${artifacts} ]"
        fi
    fi
}

# Fetches all existing asset records for the current release (paginated) and
# writes one JSON object per line into ASSETS_LIST_FILE.
# Format: {"id": <number>, "name": "<string>", "state": "<string>", "digest": "<string|null>"}
fetch_assets_list() {
    # truncate/create the file before writing fresh data
    >"${ASSETS_LIST_FILE}"

    # GitHub API paginates results; loop through pages until we get fewer items than the page size
    local page=1 resp code
    while true; do
        api_call resp code GET \
            "${GITHUB_API_URL:-https://api.github.com}/repos/${repo}/releases/${release_id}/assets?per_page=${GITHUB_PER_PAGE}&page=${page}"

        if [[ "${code}" != "200" ]]; then
            local api_error
            # Extract the error message from the API response, defaulting to "Unknown error" if not present
            api_error="$(echo "${resp}" | jq -r '.message // "Unknown error"' 2>/dev/null)"
            echo -e "${ERROR} Failed to list assets page ${page} (HTTP ${code}): ${api_error}"
            break
        fi

        local count
        count="$(echo "${resp}" | jq '. | length')"
        # Extract only the fields needed downstream; digest is the GitHub-supplied SHA-256 checksum
        echo "${resp}" | jq -c \
            '.[] | {id: .id, name: .name, state: .state, digest: (.digest // null), browser_download_url: (.browser_download_url // "")}' \
            >>"${ASSETS_LIST_FILE}"

        # Stop paging when the last page returns fewer items than the page size
        [[ "${count}" -lt "${GITHUB_PER_PAGE}" ]] && break
        page=$((page + 1))
    done

    [[ "${out_log}" == "true" && -s "${ASSETS_LIST_FILE}" ]] &&
        echo -e "${INFO} Current assets:\n$(cat "${ASSETS_LIST_FILE}")"
}

# delete_asset <asset_id> <asset_name> [file_index] [total_files]
# Sends a DELETE request for the given asset; up to RETRY_MAX_ATTEMPTS attempts total.
# Returns 0 on success (or 404 = already gone), 1 on permanent failure.
# Optional 3rd/4th args: file_index and total_files — when provided, prefix log lines with (n/N).
delete_asset() {
    local asset_id="${1}" asset_name="${2}"
    local file_index="${3:-}" total_files="${4:-}"
    # Sanitised copy for log output
    local safe_asset_name
    safe_asset_name="$(sanitize_log "${asset_name}")"
    # Build the (n/N) prefix only when caller passes index/total
    local idx_prefix=""
    [[ -n "${file_index}" && -n "${total_files}" ]] && idx_prefix="(${file_index}/${total_files})"
    local attempt=0 wait_time="${RETRY_WAIT_INIT}"
    local resp code

    # Loop through each attempt: on 200/204 return success, on 404 treat as already deleted,
    # on 429 wait and retry, on other errors apply exponential back-off and retry
    while [[ "${attempt}" -lt "${RETRY_MAX_ATTEMPTS}" ]]; do
        attempt=$((attempt + 1))

        api_call resp code DELETE \
            "${GITHUB_API_URL:-https://api.github.com}/repos/${repo}/releases/assets/${asset_id}"

        if [[ "${code}" =~ ^(200|204)$ ]]; then
            echo -e "${INFO} │  ${idx_prefix} Deleted asset: [ ${safe_asset_name} ] (id=${asset_id})"
            return 0
        elif [[ "${code}" == "404" ]]; then
            # Asset already gone — treat as success to avoid blocking upload retries
            echo -e "${NOTE} │  ${idx_prefix} Asset [ ${safe_asset_name} ] not found (already deleted), skipping."
            return 0
        elif [[ "${code}" == "429" ]]; then
            echo -e "${NOTE} │  ${idx_prefix} Rate limited while deleting [ ${safe_asset_name} ], waiting ${RATE_LIMIT_WAIT}s... (attempt ${attempt}/${RETRY_MAX_ATTEMPTS})"
            sleep "${RATE_LIMIT_WAIT}"
        else
            echo -e "${NOTE} │  ${idx_prefix} Failed to delete [ ${safe_asset_name} ] (HTTP ${code}), attempt ${attempt}/${RETRY_MAX_ATTEMPTS}"
            # Apply exponential back-off before the next attempt
            [[ "${attempt}" -lt "${RETRY_MAX_ATTEMPTS}" ]] && sleep "${wait_time}" && wait_time=$((wait_time * 2))
        fi
    done

    echo -e "${ERROR} Could not delete asset [ ${safe_asset_name} ] after ${RETRY_MAX_ATTEMPTS} attempts."
    return 1
}

# Fetches the full asset list and deletes every entry.
# Called only when remove_artifacts=true (bulk pre-upload clear).
remove_all_assets() {
    echo -e "${STEPS} Removing all existing assets from release [ ${release_id} ]..."

    fetch_assets_list

    if [[ ! -s "${ASSETS_LIST_FILE}" ]]; then
        echo -e "${NOTE} No existing assets found, skipping bulk removal."
        echo -e ""
        return
    fi

    local del_success=0 del_fail=0
    # Read one JSON object per line and delete each asset by ID
    while IFS= read -r asset_json; do
        local a_id a_name
        a_id="$(echo "${asset_json}" | jq -r '.id')"
        a_name="$(echo "${asset_json}" | jq -r '.name')"
        if delete_asset "${a_id}" "${a_name}"; then
            del_success=$((del_success + 1))
        else
            del_fail=$((del_fail + 1))
        fi
    done <"${ASSETS_LIST_FILE}"

    echo -e "${SUCCESS} Asset removal: [ ${del_success} ] succeeded, [ ${del_fail} ] failed."
    echo -e ""
}

# upload_asset <file_path> <file_index> <total_files>
# Uploads one file to the release with retry on failure.
# On success appends "filename=download_url" to UPLOAD_RESULTS_FILE.
# Returns: 0 = success, 1 = permanent failure, 2 = skipped (replaces_artifacts=false).
# On permanent failure logs an error and returns 1 (does NOT exit the script).
upload_asset() {
    local file_path="${1}"
    local file_index="${2}"
    local total_files="${3}"
    local file_name
    file_name="$(basename "${file_path}")"
    # Sanitised copy for log output — prevents workflow-command injection via filenames
    local safe_name
    safe_name="$(sanitize_log "${file_name}")"

    # Gather file metadata for the progress header
    local file_size_bytes file_size_human
    file_size_bytes="$(stat -c '%s' "${file_path}" 2>/dev/null || stat -f '%z' "${file_path}" 2>/dev/null || echo "0")"
    file_size_human="$(format_size "${file_size_bytes}")"

    # Detect MIME type from file content; fall back to generic binary stream
    local mime_type
    mime_type="$(file --brief --mime-type "${file_path}" 2>/dev/null)"
    [[ -z "${mime_type}" ]] && mime_type="application/octet-stream"

    # URL-encode the filename so special characters are safe in the query string
    local encoded_name
    encoded_name="$(url_encode "${file_name}")"

    # Format timeout information for the progress line
    local timeout_info
    if [[ "${UPLOAD_MAX_TIME}" -eq 0 ]]; then
        timeout_info="no timeout"
    else
        timeout_info="timeout=${upload_timeout}min"
    fi

    # ── Tree-border progress header ──────────────────────────────────────
    echo -e "${FILE} ┌─ (${file_index}/${total_files}) Uploading: [ ${safe_name} ]"
    echo -e "${SIZE} │  (${file_index}/${total_files}) Size: ${file_size_human}  MIME: ${mime_type}  ${timeout_info}"

    # Initialize retry loop variables
    local attempt=0 wait_time="${RETRY_WAIT_INIT}"
    # replace_cycles counts 422-triggered delete-and-retry rounds.
    # These are NOT charged against the error retry budget (attempt) because a 422
    # means the upload endpoint rejected a duplicate name — not a transient failure.
    # A separate cap prevents an infinite loop if a concurrent job keeps re-creating
    # the asset between our delete and re-upload (extreme race condition).
    local replace_cycles=0
    local MAX_REPLACE_CYCLES=5
    # true when the current iteration is a post-replace re-upload (not an error retry)
    local is_replace=false

    # Loop until upload succeeds or we exhaust retry attempts
    while [[ "${attempt}" -lt "${RETRY_MAX_ATTEMPTS}" ]]; do
        attempt=$((attempt + 1))

        # Distinguish a post-replace re-upload from a genuine error retry
        if [[ "${attempt}" -gt 1 || "${is_replace}" == "true" ]]; then
            if [[ "${is_replace}" == "true" ]]; then
                echo -e "${NOTE} │  (${file_index}/${total_files}) Re-uploading after replace..."
                is_replace=false
            else
                echo -e "${NOTE} │  (${file_index}/${total_files}) Retry attempt ${attempt}/${RETRY_MAX_ATTEMPTS}..."
            fi
        fi

        # Temp files for the response body and curl stderr
        local tmp_body tmp_stderr
        tmp_body="$(mktemp)"
        tmp_stderr="$(mktemp)"
        local start_ts http_code elapsed

        # record start time to compute elapsed seconds
        start_ts="${SECONDS}"

        # Upload via the uploads.github.com endpoint (different host from api.github.com)
        # -T (--upload-file) streams the file directly from disk without loading it into memory,
        # avoiding OOM on large files that --data-binary would cause by buffering the entire file.
        # -X POST overrides the default PUT method so the GitHub upload API receives the correct verb.
        # stderr is captured to tmp_stderr so curl errors are only printed on permanent failure.
        http_code=$(
            curl -sSL \
                --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
                --speed-limit "${UPLOAD_SPEED_LIMIT}" \
                --speed-time "${UPLOAD_SPEED_TIME}" \
                --max-time "${UPLOAD_MAX_TIME}" \
                -o "${tmp_body}" -w '%{http_code}' \
                -X POST \
                -H "Accept: application/vnd.github+json" \
                -H "Authorization: Bearer ${gh_token}" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                -H "Content-Type: ${mime_type}" \
                -T "${file_path}" \
                "${upload_url}?name=${encoded_name}" \
                2>"${tmp_stderr}"
        )
        local curl_exit="${?}"
        local response curl_stderr_msg
        response="$(cat "${tmp_body}" 2>/dev/null)"
        curl_stderr_msg="$(cat "${tmp_stderr}" 2>/dev/null)"
        rm -f "${tmp_body}" "${tmp_stderr}"

        elapsed=$((SECONDS - start_ts))

        # ── curl-level failure (timeout, network reset, stall, etc.) ─────
        if [[ "${curl_exit}" -ne 0 ]]; then
            # curl exit code 28 can mean --max-time was reached or the stall guard fired.
            # When upload_timeout=0 (UPLOAD_MAX_TIME=0), --max-time is disabled, so exit 28
            # can only come from --speed-limit/--speed-time (stall guard).
            local curl_reason="network error"
            if [[ "${curl_exit}" -eq 28 ]]; then
                if [[ "${UPLOAD_MAX_TIME}" -eq 0 ]]; then
                    curl_reason="stall timeout (speed < ${UPLOAD_SPEED_LIMIT}B/s for ${UPLOAD_SPEED_TIME}s)"
                else
                    curl_reason="upload timeout (exceeded ${upload_timeout} min)"
                fi
            fi

            echo -e "${NOTE} │  (${file_index}/${total_files}) curl error ${curl_exit} (${curl_reason}) after ${elapsed}s (attempt ${attempt}/${RETRY_MAX_ATTEMPTS})"
            if [[ "${attempt}" -lt "${RETRY_MAX_ATTEMPTS}" ]]; then
                # remove any stale partial asset before retry
                cleanup_partial_upload "${file_name}" "${file_index}" "${total_files}"
                echo -e "${NOTE} │  (${file_index}/${total_files}) Retrying in ${wait_time}s..."
                sleep "${wait_time}"
                wait_time=$((wait_time * 2))
                continue
            fi
            # Print the captured curl stderr on the final attempt to expose the root cause
            [[ -n "${curl_stderr_msg}" ]] &&
                echo -e "${WARN} │  (${file_index}/${total_files}) curl stderr: ${curl_stderr_msg}"
            echo -e "${WARN} └─ (${file_index}/${total_files}) Permanent failure: [ ${safe_name} ] (${curl_reason} after ${RETRY_MAX_ATTEMPTS} attempts). Skipping."
            echo ""
            return 1
        fi

        # ── HTTP 200/201 — upload successful ─────────────────────────────
        if [[ "${http_code}" =~ ^(200|201)$ ]]; then
            local download_url
            download_url="$(echo "${response}" | jq -r '.browser_download_url')"
            echo -e "${DONE} │  (${file_index}/${total_files}) Upload completed in ${elapsed}s: [ ${safe_name} ]"
            echo -e "${INFO} └─ (${file_index}/${total_files}) Download URL: [ ${download_url} ]"
            echo ""

            # Record result for verify_uploads and set_action_outputs to consume
            printf '%s=%s\n' "${file_name}" "${download_url}" >>"${UPLOAD_RESULTS_FILE}"
            return 0
        fi

        # ── HTTP 422: asset with this name already exists on the release ──
        if [[ "${http_code}" == "422" ]]; then
            if [[ "${replaces_artifacts}" == "true" ]]; then
                replace_cycles=$((replace_cycles + 1))
                if [[ "${replace_cycles}" -gt "${MAX_REPLACE_CYCLES}" ]]; then
                    echo -e "${WARN} └─ (${file_index}/${total_files}) Asset [ ${safe_name} ] still conflicting after ${MAX_REPLACE_CYCLES} replace cycles (concurrent upload race). Skipping."
                    echo ""
                    return 1
                fi
                echo -e "${INFO} │  (${file_index}/${total_files}) Asset [ ${safe_name} ] already exists; checking SHA-256 before replacing."
                fetch_assets_list
                local existing_id existing_digest existing_download_url
                existing_id="$(jq -r --arg n "${file_name}" \
                    'select(.name == $n) | .id' "${ASSETS_LIST_FILE}" 2>/dev/null | head -1)"
                existing_digest="$(jq -r --arg n "${file_name}" \
                    'select(.name == $n) | .digest // ""' "${ASSETS_LIST_FILE}" 2>/dev/null | head -1)"
                existing_download_url="$(jq -r --arg n "${file_name}" \
                    'select(.name == $n) | .browser_download_url // ""' "${ASSETS_LIST_FILE}" 2>/dev/null | head -1)"

                # Compare local SHA-256 against the remote digest before deciding to replace
                local local_hash_check=""
                local_hash_check="$(${SHA256_CMD} "${file_path}" 2>/dev/null | awk '{print $1}')"
                if [[ -n "${local_hash_check}" && "${existing_digest}" == "sha256:${local_hash_check}" ]]; then
                    echo -e "${DONE} │  (${file_index}/${total_files}) SHA-256 verified identical; skipping re-upload: [ ${safe_name} ]"
                    echo -e "${INFO} └─ (${file_index}/${total_files}) Download URL: [ ${existing_download_url} ]"
                    echo ""
                    # Record as skipped (not a failure); caller counts return 2 as skipped
                    return 2
                fi

                # If we get here, the existing asset is different (or has no digest) — delete it and retry the upload.
                if [[ -z "${existing_digest}" || "${existing_digest}" == "null" ]]; then
                    echo -e "${INFO} │  (${file_index}/${total_files}) No remote digest available for [ ${safe_name} ]; replacing."
                else
                    echo -e "${INFO} │  (${file_index}/${total_files}) SHA-256 mismatch for [ ${safe_name} ]; replacing."
                fi

                # Delete the existing asset so the re-upload does not hit another 422 duplicate-name conflict.
                if [[ -n "${existing_id}" ]]; then
                    delete_asset "${existing_id}" "${file_name}" "${file_index}" "${total_files}"
                fi

                # Mark as replace so the next loop iteration prints a clearer message.
                # Decrement attempt so this replace cycle does NOT consume an error retry slot.
                is_replace=true
                attempt=$((attempt - 1))
                # Re-upload immediately — no sleep needed after a delete
                continue
            else
                echo -e "${WARN} └─ (${file_index}/${total_files}) Asset [ ${safe_name} ] already exists and replaces_artifacts=false. Skipping."
                echo ""
                # return 2 = skipped (not an error, just intentionally bypassed)
                return 2
            fi
        fi

        # ── HTTP 429: server-side rate limit on the upload endpoint ──────
        # attempt is already incremented at the top of the loop, so this still counts
        # toward RETRY_MAX_ATTEMPTS — prevents an infinite loop if throttling persists.
        if [[ "${http_code}" == "429" ]]; then
            echo -e "${NOTE} │  (${file_index}/${total_files}) Rate limited, waiting ${RATE_LIMIT_WAIT}s... (attempt ${attempt}/${RETRY_MAX_ATTEMPTS})"
            sleep "${RATE_LIMIT_WAIT}"
            continue
        fi

        # ── All other HTTP errors (5xx, etc.) — back-off and retry ───────
        local api_error
        api_error="$(echo "${response}" | jq -r '.message // "Unknown error"' 2>/dev/null)"
        echo -e "${NOTE} │  (${file_index}/${total_files}) HTTP ${http_code}: ${api_error} (attempt ${attempt}/${RETRY_MAX_ATTEMPTS})"

        # Apply exponential back-off before the next attempt, but only if we have attempts left
        if [[ "${attempt}" -lt "${RETRY_MAX_ATTEMPTS}" ]]; then
            cleanup_partial_upload "${file_name}" "${file_index}" "${total_files}"
            echo -e "${NOTE} │  (${file_index}/${total_files}) Retrying in ${wait_time}s..."
            sleep "${wait_time}"
            wait_time=$((wait_time * 2))
        fi
    done

    echo -e "${WARN} └─ (${file_index}/${total_files}) Permanent failure: [ ${safe_name} ] failed after ${RETRY_MAX_ATTEMPTS} attempts. Skipping."
    echo ""
    return 1
}

# cleanup_partial_upload <file_name> <file_index> <total_files>
# If a partial (state != "uploaded") asset with this name exists on the release,
# delete it so the retry can start fresh without hitting a duplicate-name 422.
cleanup_partial_upload() {
    local file_name="${1}" file_index="${2}" total_files="${3}"
    local safe_name
    safe_name="$(sanitize_log "${file_name}")"
    # refresh asset list to reflect the latest server state
    fetch_assets_list

    # Look for an existing asset with the same name; if found, check its state
    local stale_id stale_state
    stale_id="$(jq -r --arg n "${file_name}" 'select(.name == $n) | .id' "${ASSETS_LIST_FILE}" 2>/dev/null | head -1)"
    stale_state="$(jq -r --arg n "${file_name}" 'select(.name == $n) | .state' "${ASSETS_LIST_FILE}" 2>/dev/null | head -1)"

    # Only delete if the stale asset is a partial upload (state != "uploaded").
    # Fully-uploaded assets must not be touched here — they were completed by a concurrent
    # job or an earlier attempt and are still valid.
    if [[ -n "${stale_id}" && "${stale_state}" != "uploaded" ]]; then
        echo -e "${NOTE} │  (${file_index}/${total_files}) Removing partial asset [ ${safe_name} ] (state=${stale_state}, id=${stale_id}) before retry..."
        delete_asset "${stale_id}" "${file_name}" "${file_index}" "${total_files}"
    fi
}

# Iterates resolved_files in order, calls upload_asset for each, and prints a summary.
# A failed file is skipped (upload_asset returns 1) but does not stop the remaining uploads.
upload_all_assets() {
    local total="${#resolved_files[@]}"
    echo -e "${STEPS} Starting upload of [ ${total} ] file(s) to release [ ${release_id} ]..."

    # start with an empty results file
    >"${UPLOAD_RESULTS_FILE}"

    local up_success=0 up_fail=0 up_skip=0
    local idx=0
    local skipped_files=()

    # Loop through each resolved file and attempt upload; track successes, failures, and skips for the final summary
    for file_path in "${resolved_files[@]}"; do
        idx=$((idx + 1))

        upload_asset "${file_path}" "${idx}" "${total}"
        local upload_ret="${?}"
        if [[ "${upload_ret}" -eq 0 ]]; then
            up_success=$((up_success + 1))
        elif [[ "${upload_ret}" -eq 2 ]]; then
            up_skip=$((up_skip + 1))
            skipped_files+=("${file_path}")
        else
            up_fail=$((up_fail + 1))
        fi
    done

    echo -e "${SUCCESS} Upload summary: [ ${total} ] total, [ ${up_success} ] succeeded, [ ${up_fail} ] failed, [ ${up_skip} ] skipped."

    # List failed files (not in UPLOAD_RESULTS_FILE and not in skipped_files)
    if [[ "${up_fail}" -gt 0 ]]; then
        echo -e "${NOTE} Files failed to upload:"
        for file_path in "${resolved_files[@]}"; do
            local fname
            fname="$(basename "${file_path}")"
            # Skip files that were intentionally skipped
            local is_skipped="false"
            for sf in "${skipped_files[@]}"; do
                [[ "$(basename "${sf}")" == "${fname}" ]] && is_skipped="true" && break
            done
            [[ "${is_skipped}" == "true" ]] && continue
            # Use -F (fixed string) so filenames with regex special chars (. + [ etc.) match literally
            grep -qF "${fname}=" "${UPLOAD_RESULTS_FILE}" 2>/dev/null ||
                echo -e "${NOTE}   - $(sanitize_log "${fname}")"
        done
    fi

    # List skipped files separately
    if [[ "${up_skip}" -gt 0 ]]; then
        local skip_total="${#skipped_files[@]}"
        local skip_idx=0
        local max_sfname_len=0
        local sfn sfn_padded sf_hash
        for sf_path in "${skipped_files[@]}"; do
            sfn="$(basename "${sf_path}")"
            [[ "${#sfn}" -gt "${max_sfname_len}" ]] && max_sfname_len="${#sfn}"
        done
        for sf_path in "${skipped_files[@]}"; do
            skip_idx=$((skip_idx + 1))
            sfn="$(sanitize_log "$(basename "${sf_path}")")"
            printf -v sfn_padded "%-${max_sfname_len}s" "${sfn}"
            sf_hash="$(${SHA256_CMD} "${sf_path}" 2>/dev/null | awk '{print $1}')"
            if [[ -n "${sf_hash}" ]]; then
                echo -e "${INFO} SKIPPED  ${skip_idx}/${skip_total} [ ${sfn_padded} ]  [ sha256:${sf_hash} ]"
            else
                echo -e "${INFO} SKIPPED  ${skip_idx}/${skip_total} [ ${sfn} ]"
            fi
        done
    fi

    echo -e ""

    # Abort with a non-zero exit only if every single file actually failed (skipped = SHA-256 identical = success)
    [[ "${up_success}" -eq 0 && "${up_skip}" -eq 0 ]] && error_msg "All [ ${total} ] file(s) failed to upload. Aborting."
}

# For each successfully uploaded file, computes the local SHA-256 checksum and
# compares it against the value returned by the GitHub Releases assets API.
#
# GitHub API asset object includes a "digest" field (format: "sha256:<hex>")
# when the asset was uploaded with the 2022-11-28 API version.
# If the API does not return a digest (older releases / missing field), the
# file is skipped rather than downloaded — verification is only performed when
# the API supplies the checksum directly.
#
# Results are printed in a numbered table and a final pass/fail summary is shown.
# Verification failures are non-fatal — the overall script still exits 0
# unless every single upload failed.
verify_uploads() {
    echo -e "${STEPS} Verifying upload integrity (SHA-256)..."

    if [[ ! -s "${UPLOAD_RESULTS_FILE}" ]]; then
        echo -e "${NOTE} No successfully uploaded files to verify."
        echo -e ""
        return
    fi

    # Refresh asset list to get the latest digests from the API
    fetch_assets_list

    local verify_pass=0 verify_fail=0 verify_skip=0

    # Pre-count total entries so each line can show n/total progress
    local verify_total
    verify_total="$(grep -c '=' "${UPLOAD_RESULTS_FILE}" 2>/dev/null || echo 0)"
    local verify_idx=0

    # Pre-compute the longest filename so all columns can be padded to the same width
    local max_fname_len=0
    while IFS= read -r result_line; do
        local entry_name="${result_line%%=*}"
        [[ "${#entry_name}" -gt "${max_fname_len}" ]] && max_fname_len="${#entry_name}"
    done <"${UPLOAD_RESULTS_FILE}"

    echo -e "${INFO} ────────────────────────────────────────────────────────────────────────"

    # Build a basename-to-path map for O(1) lookup during verification
    declare -A file_path_map
    for f in "${resolved_files[@]}"; do
        file_path_map["$(basename "${f}")"]="${f}"
    done

    # Each line in UPLOAD_RESULTS_FILE has the format: filename=download_url
    # IFS= read -r line + parameter expansion splits on the FIRST '=' only,
    # avoiding URL truncation when the download URL itself contains '=' characters
    # (e.g. GitHub CDN signed URLs with query parameters like ?X-Amz-Signature=...).
    while IFS= read -r line; do
        fname="${line%%=*}"
        furl="${line#*=}"
        [[ -z "${fname}" || -z "${furl}" ]] && continue

        verify_idx=$((verify_idx + 1))

        # Pad filename to the max width so the sha256 column stays vertically aligned
        local fname_padded
        printf -v fname_padded "%-${max_fname_len}s" "$(sanitize_log "${fname}")"

        # Locate the original local file path using O(1) associative array lookup
        local local_path="${file_path_map[${fname}]:-}"

        if [[ -z "${local_path}" || ! -f "${local_path}" ]]; then
            echo -e "${NOTE} SKIP ${verify_idx}/${verify_total} [ ${fname_padded} ] (local file not found)"
            verify_skip=$((verify_skip + 1))
            continue
        fi

        # Compute local SHA-256; awk extracts only the hash (first field of sha256sum output)
        local local_hash
        local_hash="$(${SHA256_CMD} "${local_path}" 2>/dev/null | awk '{print $1}')"

        if [[ -z "${local_hash}" ]]; then
            echo -e "${NOTE} SKIP ${verify_idx}/${verify_total} [ ${fname_padded} ] (could not compute local SHA-256)"
            verify_skip=$((verify_skip + 1))
            continue
        fi

        # Retrieve remote digest from cached asset list
        # GitHub API returns digest as "sha256:<hex>" in the digest field (API version 2022-11-28)
        local remote_digest remote_hash=""
        remote_digest="$(jq -r --arg n "${fname}" \
            'select(.name == $n) | .digest // ""' "${ASSETS_LIST_FILE}" 2>/dev/null | head -1)"

        if [[ "${remote_digest}" == sha256:* ]]; then
            # Preferred path: strip the "sha256:" prefix and use the hex value directly
            remote_hash="${remote_digest#sha256:}"
        else
            # No digest field returned by the API (older release) — skip rather than download
            echo -e "${NOTE} SKIP ${verify_idx}/${verify_total} [ ${fname_padded} ] (no digest field in API response)"
            verify_skip=$((verify_skip + 1))
            continue
        fi

        # Compare local and remote hashes; print OK or FAIL per file
        if [[ "${local_hash}" == "${remote_hash}" ]]; then
            echo -e "${SUCCESS} OK   ${verify_idx}/${verify_total} [ ${fname_padded} ]  [ sha256:${local_hash} ]"
            verify_pass=$((verify_pass + 1))
        else
            echo -e "${ERROR} FAIL ${verify_idx}/${verify_total} [ ${fname_padded} ]"
            echo -e "${ERROR}      local:  ${local_hash}"
            echo -e "${ERROR}      remote: ${remote_hash}"
            verify_fail=$((verify_fail + 1))
        fi

    done <"${UPLOAD_RESULTS_FILE}"

    echo -e "${INFO} ────────────────────────────────────────────────────────────────────────"
    echo -e "${SUCCESS} Integrity summary: [ $((verify_pass + verify_fail + verify_skip)) ] total, [ ${verify_pass} ] passed, [ ${verify_fail} ] failed, [ ${verify_skip} ] skipped."
    echo -e ""
}

# Builds the assets JSON map from UPLOAD_RESULTS_FILE and writes all four
# output variables (release_id, html_url, upload_url, assets) to GITHUB_OUTPUT.
set_action_outputs() {
    # Build a JSON object mapping filename → download URL from the results file.
    # Each line has the form:  filename=https://...  (first '=' is the delimiter;
    # download URLs may contain '=' in query parameters so we split on the first only).
    # A single jq invocation handles all lines at once, avoiding one subprocess per file.
    local assets_json="{}"
    if [[ -s "${UPLOAD_RESULTS_FILE}" ]]; then
        assets_json="$(
            jq -Rsc '
                [split("\n")[] | select(length > 0) |
                 { key: (index("=") as $i | .[:$i]),
                   value: (index("=") as $i | .[$i+1:]) }
                ] | from_entries
            ' "${UPLOAD_RESULTS_FILE}"
        )"
        # Fall back to empty object on jq failure (e.g. malformed file)
        [[ -z "${assets_json}" ]] && assets_json="{}"
    fi

    echo -e "${INFO} Writing action outputs..."
    # Append to GITHUB_OUTPUT using the heredoc delimiter format.
    # This is the GitHub-recommended approach that safely handles values
    # containing newlines, special characters, or workflow command prefixes.
    # Reference: https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions#multiline-strings
    local delimiter="ghadelimiter_b8f5c3e2"
    {
        echo "release_id<<${delimiter}"
        echo "${release_id}"
        echo "${delimiter}"
        echo "html_url<<${delimiter}"
        echo "${html_url}"
        echo "${delimiter}"
        echo "upload_url<<${delimiter}"
        echo "${upload_url}"
        echo "${delimiter}"
        echo "assets<<${delimiter}"
        echo "${assets_json}"
        echo "${delimiter}"
    } >>"${GITHUB_OUTPUT:-/dev/null}"

    echo -e "${INFO} release_id:  [ ${release_id} ]"
    echo -e "${INFO} html_url:    [ ${html_url} ]"
    echo -e "${INFO} upload_url:  [ ${upload_url} ]"
    [[ "${out_log}" == "true" ]] && echo -e "${INFO} assets: ${assets_json}"
}

echo -e "${STEPS} Welcome! Starting upload to GitHub Releases."

# Bash 4.3+ is required for:
#   • declare -A (associative arrays, bash 4.0+)
#   • declare -n (nameref variables, bash 4.3+)
# macOS system bash is 3.2; GitHub-hosted runners provide bash 5.x via Homebrew.
if [[ "${BASH_VERSINFO[0]}" -lt 4 || ("${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 3) ]]; then
    echo -e "${ERROR} bash 4.3+ required (current: ${BASH_VERSION})."
    echo -e "${NOTE} On macOS, install a newer bash: brew install bash"
    exit 1
fi

# PID-suffixed temp file names in /tmp avoid collisions when multiple workflow jobs run in parallel
ASSETS_LIST_FILE="/tmp/json_assets_list_$$"
UPLOAD_RESULTS_FILE="/tmp/json_upload_results_$$"

# Register cleanup handler so temp files are removed on any exit (normal or error)
trap cleanup EXIT

# Step 1: Install dependencies
install_dependencies
# Step 2: Initialize and validate all parameters
init_var
# Step 3: Expand artifact glob / comma-separated patterns into a numbered file list
expand_artifacts
# Step 4: Ensure the target release exists; create or update as appropriate
ensure_release
# Step 5: Optionally remove all pre-existing release assets before uploading
[[ "${remove_artifacts}" == "true" ]] && remove_all_assets
# Step 6: Upload every resolved file; skip on permanent failure, continue for the rest
upload_all_assets
# Step 7: Verify SHA-256 integrity of every successfully uploaded file
verify_uploads
# Step 8: Publish release ID, URLs, and asset map as action outputs
set_action_outputs

echo -e "${SUCCESS} All upload operations finished."
