#!/bin/bash

# UP 2xx or 3xx
# DOWN 4xx or 5xx
# UNREACHABLE connection refused or timeots

# EXIT CODES: 0 = UP, 1 = DOWN, 2 = UNREACHABLE, 3 = usage error

set -euo pipefail

URL="https://wisecow.local"
TIMEOUT=10
LOGFILE=""
INSECURE=false
RESOLVE=""

usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Check application is up (inspect HTTP status code)

Options:
  -u, --url URL		URL to check (default: ${URL})
  -t, --timeout SECS	Request timeout in seconds (default: ${TIMEOUT})
  -l, --log FILE	Append results to a log file as well as stdout
  -k, --insecure	Skip TLS verification (for self-signed certificates)
  -r, --resolve SPEC	Force DNS resolution
  -h, --help		Show this help and exit

Exit codes:
  0	UP		HTTP 2xx/3xx
  1	DOWN		HTTP 4xx/5xx
  2	UNREACHABLE	connection failed or timed out
  3	usage error

Examples:
  $(basename "$0") --url https://wisecow.local --insecure
  $(basename "$0") -u https://wisecow.local -k -l /var/log/wisecow-health.log
  $(basename "$0") -u https://wisecow.local -k -r wisecow.local:443:127.0.0.1
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)      URL="${2:-}";      shift 2 ;;
        -t|--timeout)  TIMEOUT="${2:-}";  shift 2 ;;
        -l|--log)      LOGFILE="${2:-}";  shift 2 ;;
        -r|--resolve)  RESOLVE="${2:-}";  shift 2 ;;
        -k|--insecure) INSECURE=true;     shift   ;;
        -h|--help)     usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 3
            ;;
    esac
done

if [[ -z "$URL" ]]; then
    echo "Error: --url cannot be empty" >&2
    exit 3
fi
 
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
    echo "Error: --timeout must be a positive integer" >&2
    exit 3
fi

command -v curl >/dev/null 2>&1 || { echo "Error: curl is required" >&2; exit 3; }

log() {
  local level="$1" message="$2"
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${message}"

  echo "$line"

  if [[ -n "$LOGFILE" ]]; then
	  mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
	  echo "$line" >> "$LOGFILE" 2>/dev/null \
		  || echo "Warning: could not write to ${LOGFILE}" >&2
  fi
}

CURL_ARGS=(
  --silent
  --show-error
  --output /dev/null
  --max-time "$TIMEOUT"
  --write-out '%{http_code} %{time_total}'
)

[[ "$INSECURE" == true ]]	&& CURL_ARGS+=(--insecure)
[[ -n "$RESOLVE" ]]		&& CURL_ARGS+=(--resolve "$RESOLVE")

rc=0
RESPONSE="$(curl "${CURL_ARGS[@]}" "$URL" 2>/dev/null)" || rc=$?

if [[ $rc -ne 0 ]]; then
	case $rc in
		6)	reason="could not resolve host" ;;
		7)	reason="connection refused" ;;
		28)	reason="timed out after ${TIMEOUT}s" ;;
		35)	reason="TLS handshake failed" ;;
		60)	reason="TLS certificate verification failed (use --insecure for self-signed)" ;;
		*)	reason="curl exit code ${rc}" ;;
	esac
	log "CRITICAL" "UNREACHABLE ${URL} - ${reason}"
	exit 2
fi

HTTP_CODE="${RESPONSE%% *}"
TIME_TOTAL="${RESPONSE##* }"

if [[ "$HTTP_CODE" =~ ^[23][0-9]{2}$ ]]; then
	log "INFO" "UP	${URL}	- HTTP ${HTTP_CODE} in ${TIME_TOTAL}s"
	exit 0
elif [[ "$HTTP_CODE" =~ ^[45][0-9]{2}$ ]]; then
	log "ERROR" "DOWN	${URL}	- HTTP ${HTTP_CODE} in ${TIME_TOTAL}s"
	exit 1
else
	log "ERROR" "DOWN	${URL}	- unexpected HTTP ${HTTP_CODE} in ${TIME_TOTAL}s"
	exit 1
fi
