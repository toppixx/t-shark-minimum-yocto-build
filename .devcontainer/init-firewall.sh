#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

DOCKER_DNS="127.0.0.11"   # Docker's internal resolver — always this address

# ---------------------------------------------------------------------------
# L-1: CIDR/IP validation helpers with proper range checking
# ---------------------------------------------------------------------------
validate_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" \
          o3="${BASH_REMATCH[3]}" o4="${BASH_REMATCH[4]}" prefix="${BASH_REMATCH[5]}"
    [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && \
    [ "$o4" -le 255 ] && [ "$prefix" -le 32 ]
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] && \
    [ "${BASH_REMATCH[3]}" -le 255 ] && [ "${BASH_REMATCH[4]}" -le 255 ]
}

# ---------------------------------------------------------------------------
# 1. Extract Docker DNS NAT rules BEFORE flushing
# ---------------------------------------------------------------------------
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# ---------------------------------------------------------------------------
# H-4: Restore Docker DNS NAT rules safely.
# Instead of replaying raw iptables-save output through xargs (which passes
# arbitrary arguments to iptables), extract only the dynamic port numbers
# and reconstruct the rules from fixed templates.
# ---------------------------------------------------------------------------
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true

    # Extract the dynamic ports Docker assigned to its DNS proxy
    TCP_DNS_PORT=$(echo "$DOCKER_DNS_RULES" | \
        grep -oP "127\.0\.0\.11:\K[0-9]+" | head -1 || true)
    UDP_DNS_PORT=$(echo "$DOCKER_DNS_RULES" | \
        grep -oP "127\.0\.0\.11:\K[0-9]+" | tail -1 || true)

    for port in "$TCP_DNS_PORT" "$UDP_DNS_PORT"; do
        [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || continue
        iptables -t nat -A OUTPUT \
            -d "$DOCKER_DNS/32" -p tcp -m tcp --dport 53 \
            -j DNAT --to-destination "$DOCKER_DNS:$port" 2>/dev/null || true
        iptables -t nat -A OUTPUT \
            -d "$DOCKER_DNS/32" -p udp -m udp --dport 53 \
            -j DNAT --to-destination "$DOCKER_DNS:$port" 2>/dev/null || true
        iptables -t nat -A POSTROUTING \
            -s "$DOCKER_DNS/32" -p tcp -m tcp --sport "$port" \
            -j SNAT --to-source :53 2>/dev/null || true
        iptables -t nat -A POSTROUTING \
            -s "$DOCKER_DNS/32" -p udp -m udp --sport "$port" \
            -j SNAT --to-source :53 2>/dev/null || true
    done
else
    echo "No Docker DNS rules to restore"
fi

# ---------------------------------------------------------------------------
# M-5: Restrict DNS egress to Docker's internal resolver ONLY.
# Allowing UDP/53 to any destination enables DNS tunneling exfiltration.
# ---------------------------------------------------------------------------
iptables -A OUTPUT -p udp -d "$DOCKER_DNS" --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp -d "$DOCKER_DNS" --dport 53 -j ACCEPT
iptables -A INPUT  -p udp -s "$DOCKER_DNS" --sport 53 -j ACCEPT
iptables -A INPUT  -p tcp -s "$DOCKER_DNS" --sport 53 -j ACCEPT

# L-6: SSH egress removed — all git clones use HTTPS, port 22 is not needed.

# Allow localhost
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# ---------------------------------------------------------------------------
# Create ipset
# ---------------------------------------------------------------------------
ipset create allowed-domains hash:net

# ---------------------------------------------------------------------------
# M-3: Hardcoded GitHub CIDR fallback.
# The live GitHub meta API is fetched BEFORE the firewall is fully active,
# so a MITM could influence the allowlist. The hardcoded ranges below are the
# minimum known-good set; the live API can only extend (not replace) them.
# Refresh these from https://api.github.com/meta when GitHub publishes changes.
# ---------------------------------------------------------------------------
GITHUB_FALLBACK_CIDRS=(
    "192.30.252.0/22"
    "185.199.108.0/22"
    "140.82.112.0/20"
    "143.55.64.0/20"
    "20.201.28.151/32"
    "20.205.243.166/32"
    "20.87.225.212/32"
    "20.248.137.48/32"
    "20.207.73.82/32"
    "20.27.177.113/32"
    "20.200.245.247/32"
    "20.233.54.53/32"
)

echo "Adding hardcoded GitHub fallback CIDRs..."
for cidr in "${GITHUB_FALLBACK_CIDRS[@]}"; do
    if validate_cidr "$cidr"; then
        ipset add --exist allowed-domains "$cidr"
    else
        echo "ERROR: Invalid hardcoded CIDR $cidr — update GITHUB_FALLBACK_CIDRS" >&2
        exit 1
    fi
done

# Fetch live GitHub IP ranges and add any additional CIDRs not in the fallback
echo "Fetching live GitHub IP ranges..."
gh_ranges=$(curl -s --max-time 10 https://api.github.com/meta || true)

if [ -z "$gh_ranges" ]; then
    echo "WARN: Failed to fetch live GitHub IP ranges — using hardcoded fallback only"
else
    if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
        echo "WARN: GitHub API response missing expected fields — using hardcoded fallback only"
    else
        echo "Processing live GitHub IPs..."
        while read -r cidr; do
            if ! validate_cidr "$cidr"; then
                echo "WARN: Skipping invalid CIDR from live API: $cidr"
                continue
            fi
            ipset add --exist allowed-domains "$cidr"
        done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q 2>/dev/null || \
                 echo "$gh_ranges" | jq -r '(.web + .api + .git)[]')
    fi
fi

# ---------------------------------------------------------------------------
# M-4: Resolve other allowed domains.
# DNS resolution uses the Docker internal resolver (127.0.0.11) which
# forwards to the host's configured resolver. While full DNSSEC validation
# is not enforced here, restricting DNS egress to 127.0.0.11 (above) limits
# the attack surface to the host's resolver trust chain.
# ---------------------------------------------------------------------------
for domain in \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "sentry.io" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "playwright.azureedge.net" \
    "skill.fish" \
    "api.skill.fish" \
    "update.code.visualstudio.com"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi
    while read -r ip; do
        if ! validate_ip "$ip"; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add --exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# Optional domains — warn but don't fail
for domain in \
    "statsig.anthropic.com" \
    "statsig.com"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARN: Failed to resolve $domain (skipping)"
        continue
    fi
    while read -r ip; do
        if ! validate_ip "$ip"; then
            echo "WARN: Invalid IP from DNS for $domain: $ip (skipping)"
            continue
        fi
        echo "Adding $ip for $domain"
        ipset add --exist allowed-domains "$ip"
    done < <(echo "$ips")
done

# ---------------------------------------------------------------------------
# Allow host network access
# ---------------------------------------------------------------------------
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# ---------------------------------------------------------------------------
# Apply default-deny policies and remaining rules
# ---------------------------------------------------------------------------
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed — able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed — unable to reach https://example.com"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed — unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed — able to reach https://api.github.com"
fi
