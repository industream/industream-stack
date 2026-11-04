#!/usr/bin/env bash
# Called after the complete env-file chain has been sourced. Output is a
# literal CSV, so Swarm never has to expand a nested ${A:-${B}} expression.
datacatalog_cors_origins() {
  if [[ -n "${DATACATALOG_CORS_ALLOWED_ORIGINS:-}" ]]; then
    printf '%s' "$DATACATALOG_CORS_ALLOWED_ORIGINS"
    return
  fi
  local domain="${INDUSTREAM_DOMAIN:-}" hub="${INDUSTREAM_HUB_ORIGIN:-}"
  local flowmaker=flowmaker hub_prefix=
  if [[ "${RUNTIME:-swarm}" == compose ]]; then
    domain="${FM_DOMAIN:-$domain}"
    flowmaker=frontend
    hub_prefix=hub.
  fi
  if [[ -z "$domain" ]]; then
    printf '%s' "${hub:-http://localhost:5173}"
    return
  fi
  printf '%s' "${hub:-https://$hub_prefix$domain},https://$flowmaker.$domain,https://datacatalog-ui.$domain"
}
