#!/bin/bash

set -euo pipefail
rc=0
trap 'rc=$?; echo >&2 "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $rc' ERR

key_url_path=.well-known/appspecific/com.tesla.3p.public-key.pem

declare -r default_region=EMEA

function get_scopes() {
    local -a scopes=(
        openid
        offline_access
        user_data
        vehicle_device_data
        vehicle_location
        vehicle_cmds
        vehicle_charging_cmds
        # energy_device_data
        # energy_cmds
    )

    (
        IFS=" "
        echo "${scopes[*]}"
    )
}

function get_cloudflare_token() {
    local secrets_dir="$1"
    local cloudflare_tocker_file_path="${secrets_dir}"/cloudflare_token.env
    local TUNNEL_TOKEN=""

    if [[ ! -f "${cloudflare_tocker_file_path}" ]]; then
        >&2 echo "File ${cloudflare_tocker_file_path} not found"
        >&2 printf "Enter your cloudflare tunnel token\n>>>"
        read -r TUNNEL_TOKEN
        echo "TUNNEL_TOKEN=${TUNNEL_TOKEN}" >"${cloudflare_tocker_file_path}"
    else
        # shellcheck disable=SC1090
        source "${cloudflare_tocker_file_path}"
        if [[ -z "${TUNNEL_TOKEN}" ]]; then
            >&2 echo "Fatal: expected a line \`TUNNEL_TOKEN=<token>\` in ${cloudflare_tocker_file_path}."
            >&2 echo "Either delete ${cloudflare_tocker_file_path} and let the script to recreate it,"
            >&2 echo "or edit it manually"
            exit 1
        fi
    fi

    echo "${TUNNEL_TOKEN}"
}

function gen_tesla_keys() {
    local secrets_dir="$1"

    if [[ ! -f "${secrets_dir}"/private-key.pem ]]; then
        openssl ecparam -name prime256v1 -genkey -noout -out "${secrets_dir}"/private-key.pem
        openssl ec -in "${secrets_dir}"/private-key.pem -pubout -out "${secrets_dir}"/public-key.pem
    else
        echo "Skip creating ssl keys"
    fi
}

function tunnel_start() {
    local cloudflare_token=""

    cloudflare_token="$(get_cloudflare_token "${secrets_dir}")"

    cloudflared service install "${cloudflare_token}"
}

function get_partner_token() {
    local secrets_dir="$1"
    local audience="$2"
    local client_id=""
    local client_secret=""

    >&2 echo "Requesting partner token"

    if ! creds="$(get_tesla_creds "${secrets_dir}")"; then
        echo "Error: get_tesla_creds failed." >&2
        exit 1
    fi
    read -r client_id client_secret <<< "${creds}"

    local resp=""
    resp="$(curl --silent --request POST \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=client_credentials' \
        --data-urlencode "client_id=${client_id}" \
        --data-urlencode "client_secret=${client_secret}" \
        --data-urlencode "scope=$(get_scopes)" \
        --data-urlencode "audience=${audience}" \
        'https://auth.tesla.com/oauth2/v3/token')"

    # >&2 jq . <<< "${resp}"
    jq --raw-output '.access_token' <<<"${resp}"
}

function register_app() {
    local domain="$1"
    local token="$2"
    local base_url="$3"

    >&2 echo "Registering thirdparty app"

    # That's odd, but request doesn't work with https://
    domain="${domain#https://}"

    curl --silent --request POST \
        --header "Authorization: Bearer ${token}" \
        --header "Content-Type: application/json", \
        --data "{\"domain\": \"${domain}\"}" \
        "${base_url}"/api/1/partner_accounts
}

function  verify_registered_app() {
    local domain="$1"
    local token="$2"
    local base_url="$3"

    # That's odd, but request doesn't work with https://
    domain="${domain#https://}"

        # --data "{\"domain\": \"${domain}\"}" \
    local json=""
    json="$(curl --silent --request GET \
        --header "Authorization: Bearer ${token}" \
        --header "Content-Type: application/json", \
        "${base_url}"/api/1/partner_accounts/public_key?domain="${domain}")"
    local received_key=""
    received_key="$(jq --raw-output '.response.public_key' <<<"${json}")"

    hex="$(2>/dev/null openssl ec -pubin -in /secrets/public-key.pem -text -noout)"

    # 1. Extract lines between 'pub:' and 'ASN1 OID:'
    hex="$(sed -n '/^pub:/, /ASN1 OID:/p' <<< "${hex}")"

    # 2. Remove '^pub:' lines
    hex="$(grep -v '^pub:' <<< "${hex}")"

    # 3. Remove '^ASN1 OID:' lines, spaces, newlines, and colons
    hex="$(grep -v '^ASN1 OID:' <<< "${hex}" | tr -d ' \n:')"
    
    if [[ "${received_key}" != "${hex}" ]]; then
        >&2 echo "Fatal: public key mismatch"
        >&2 echo "Expected: ${hex}"
        >&2 echo "Received: ${received_key}"
        exit 1
    fi

    echo "Public key returned from tesla matches the one we have - registration successful"
}

function usage() {
    >&2 cat <<EOF
Helper script to bootstrap certificates and register 3p app at developer.tesla.com

Usage:
  $(basename "$0") --domain <FQDN>

Options:
  -h, --help                Print this help message and exit
EOF

    exit 1
}

function get_tesla_creds() {
    local secrets_dir="$1"
    local creds_file_path="${secrets_dir}/tesla_app_credentials.txt"

    local client_id=""
    local client_secret=""

    if [[ -f "${creds_file_path}" ]]; then
        # shellcheck disable=SC1090
        source "${creds_file_path}"
        if [[ -z "${client_id}" || -z "${client_secret}" ]]; then
            >&2 echo "Client_id and/or client_secret not found in ${creds_file_path}"
            >&2 echo "Either fix file or deleted and let script to help you to create it"
            exit 1
        fi
        echo "${client_id}" "${client_secret}"
    else
        >&2 echo "File ${creds_file_path} not found"
        >&2 echo "Go to https://developer.tesla.com and register an account"
        >&2 printf "Once you done that enter your client id here\n>>>"
        read -r client_id

        >&2 printf "And now enter client secret\n>>>"
        read -r client_secret

        echo "client_id='${client_id}'" >"${creds_file_path}"
        echo "client_secret='${client_secret}'" >>"${creds_file_path}"
    fi

    echo "${client_id}" "${client_secret}"
}

function check_public_key() {
    local secrets_dir="$1"
    local domain="$2"
    local downloaded_key=""
    local expected_key=""

    local full_url="${domain}"/"${key_url_path}"

    printf "Waiting for %s becomes available." "${full_url}"
    local available=false
    # shellcheck disable=SC2034
    for i in {1..10}; do
        if curl --output /dev/null --silent --head --fail "${full_url}"; then
            available=true
            break
        fi
        sleep 2
        printf "."
    done

    if [[ "${available}" == false ]]; then
        printf "\n ... giving up"
        exit 1
    fi

    printf "\n"

    downloaded_key="$(curl -s "${full_url}")"
    expected_key="$(<"${secrets_dir}"/public-key.pem)"

    if [[ "${downloaded_key}" != "${expected_key}" ]]; then
        >&2 echo "Fatal: downloaded public key is incorrect"
        exit 1
    fi
}

function normalize_url() {
    url="$1" # Accept URL as the first argument to the script

    #strip trailing slash
    url="${url%/}"

    if [[ "$url" =~ ^http:// ]]; then
        >&2 echo "Error: URL starts with http. Please use https."
        exit 1
    elif [[ "${url}" =~ ^https:// ]]; then
        # Do nothing for URLs starting with https
        echo "${url}"
    else
        # Add https:// if the URL has no scheme
        echo "https://${url}"
    fi
}

function get_available_regions_help() {
    echo "Available regions: "
    echo "  - EMEA -> Europe, Middle East, Afric"
    echo "  - NA_APAC -> North America, Asia-Pacific (excluding China)"
    echo "For further details refer to https://developer.tesla.com/docs/fleet-api/getting-started/base-urls"
}

function get_base_url() {
    local region="$1"

    case "${region}" in
        EMEA)
            echo https://fleet-api.prd.eu.vn.cloud.tesla.com
            return
            ;;
        NA_APAC)
            echo https://fleet-api.prd.na.vn.cloud.tesla.com
            return
            ;;
        *)
            >&2 echo "Unknown region ${region}."
            >&2 get_available_regions_help
            exit 1
            ;;
    esac
}

function main() {
    local secrets_dir=/secrets
    local token=unknown

    local short_options="d:r:h"
    local long_options=domain:,region:,no-cf-tunnel,skip-https-check,help

    local domain=""
    local region="${default_region}"
    local base_url=""
    local no_cf_tunnel=false
    local skip_https_check=false

    OPTS="$(getopt -o "${short_options}" --long "${long_options}" -n "$(basename "$0")" -- "$@")"
    eval set -- "${OPTS}"
    while true; do
        case "$1" in
            -d | --domain)
                domain="$(normalize_url "$2")"
                shift 2
                ;;
            -r | --region)
                region="$2"
                shift 2
                ;;
            -h | --help)
                shift 1
                usage
                ;;
            --no-cf-tunnel)
                no_cf_tunnel=true
                shift 1
                ;;
            --skip-https-check)
                skip_https_check=true
                shift 1
                ;;
            --)
                shift
                break
                ;;
            *)
                >&2 echo "Unknown option $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "${domain}" ]]; then
        >&2 echo "Missing required option --domain"
        exit 1
    fi

    base_url="$(get_base_url "${region}")"


    gen_tesla_keys "${secrets_dir}"
    mkdir -p /opt/serve/"$(dirname "${key_url_path}")"
    ln -s "$(readlink -f "${secrets_dir}"/public-key.pem)" /opt/serve/"${key_url_path}"

    if [[ "${no_cf_tunnel}" == false ]]; then
        tunnel_start "${secrets_dir}"
        caddy start -c /root/Caddyfile 2>/var/log/caddy_startup.log
    else
        caddy start -c /root/Caddyfile-nocf 2>/var/log/caddy_startup.log
    fi

    if [[ "${skip_https_check}" == false ]]; then
        check_public_key "${secrets_dir}" "${domain}"
    else
        >&2 echo "Skip checking public key. Waiting 10secods instead."
        >&2 echo "  If you are enabeling this option because your ISP doesn't let you to access your own share from you own external IP"
        >&2 echo "  you might still want to check if"
        >&2 echo "  ${domain}/${key_url_path}"
        >&2 echo "  is available from your phone or other network"
        sleep 10
    fi

    token="$(get_partner_token "${secrets_dir}" "${base_url}")"
    local resp=""
    resp="$(register_app "${domain}" "${token}" "${base_url}")"
    echo "${resp}" >"${secrets_dir}"/register_app_resp.jq
    >&2 jq . <<<"${resp}"

    verify_registered_app "${domain}" "${token}" "${base_url}"

}

main "$@"
