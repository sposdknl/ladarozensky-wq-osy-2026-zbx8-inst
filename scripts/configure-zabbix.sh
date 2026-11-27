#!/usr/bin/env bash
# Nastavení Zabbixu přes API (běží po install-zabbix.sh):
#   - místní Debian 13 jako host se šablonou "Linux by Zabbix agent" (Agent 2)
#   - import hosta sposdk.cz ze Zabbix/export/sposdk.cz_hosts.yaml (TLS certifikát)
#   - náhodné heslo pro účet Admin místo výchozího "zabbix"
# Vše kontroluje před vytvořením, takže opakované spuštění nic nezdvojí.

set -Eeuo pipefail
trap 'echo "CHYBA: řádek $LINENO, příkaz: $BASH_COMMAND" >&2' ERR

ZBX_HOSTNAME="${ZBX_HOSTNAME:-mejp-debian13}"
API_URL="${ZBX_API_URL:-http://127.0.0.1/zabbix/api_jsonrpc.php}"
SECRET_DIR="${ZBX_SECRET_DIR:-/root/zabbix-secrets}"
ADMIN_FILE="$SECRET_DIR/admin-password"
EXPORT_FILE="/tmp/sposdk.cz_hosts.yaml"
LAB_GROUP="SPOŠ DK Lab"
TOKEN=""

log() { printf '\n==> %s\n' "$*"; }
die() { echo "CHYBA: $*" >&2; exit 1; }

# api <metoda> <JSON parametry>  -> vypíše .result, při chybě API skončí
api() {
    local body resp
    body=$(jq -cn --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0", method:$m, params:$p, id:1}')
    local -a hdr=(-H 'Content-Type: application/json-rpc')
    [[ -n $TOKEN ]] && hdr+=(-H "Authorization: Bearer $TOKEN")
    resp=$(curl -sS --max-time 60 "${hdr[@]}" -d "$body" "$API_URL") || die "API $1: spojení selhalo"
    if jq -e 'has("error")' >/dev/null <<<"$resp"; then
        echo "API $1: $(jq -c .error <<<"$resp")" >&2
        return 1
    fi
    jq -c '.result' <<<"$resp"
}

# ---------------------------------------------------------------------------
log "Čekám na Zabbix API"
for _ in $(seq 1 60); do
    ver=$(api apiinfo.version '{}' 2>/dev/null | jq -r . 2>/dev/null) && [[ -n $ver ]] && break
    sleep 2
done
[[ -n ${ver:-} ]] || die "Zabbix API na $API_URL neodpovídá"
echo "Zabbix API verze $ver"
[[ $ver == 8.0.* ]] || die "čekám Zabbix 8.0.x, API hlásí $ver"

# ---------------------------------------------------------------------------
log "Přihlášení jako Admin"
if [[ -s $ADMIN_FILE ]]; then ADMIN_PASS=$(<"$ADMIN_FILE"); else ADMIN_PASS="zabbix"; fi
TOKEN=$(api user.login "$(jq -cn --arg p "$ADMIN_PASS" '{username:"Admin", password:$p}')" | jq -r .) \
    || die "přihlášení Admin selhalo (heslo v $ADMIN_FILE?)"

# Pomocné funkce -------------------------------------------------------------
group_id() {   # vrátí ID skupiny hostů, případně ji vytvoří
    local id
    id=$(api hostgroup.get "$(jq -cn --arg n "$1" '{output:["groupid"], filter:{name:[$n]}}')" | jq -r '.[0].groupid // empty')
    [[ -n $id ]] || id=$(api hostgroup.create "$(jq -cn --arg n "$1" '{name:$n}')" | jq -r '.groupids[0]')
    echo "$id"
}
template_id() {   # vrátí ID šablony podle názvu (prázdné, když neexistuje)
    api template.get "$(jq -cn --arg n "$1" '{output:["templateid"], filter:{host:[$n]}}')" | jq -r '.[0].templateid // empty'
}
host_id() {
    api host.get "$(jq -cn --arg n "$1" '{output:["hostid"], filter:{host:[$n]}}')" | jq -r '.[0].hostid // empty'
}
check_now() {   # požádá server o okamžitý sběr položek a discovery pravidel hosta
    local hid=$1 ids
    ids=$( { api item.get "$(jq -cn --arg h "$hid" '{output:["itemid"], hostids:[$h], filter:{type:0}, templated:false}')";
             api discoveryrule.get "$(jq -cn --arg h "$hid" '{output:["itemid"], hostids:[$h]}')"; } \
           | jq -s -c '[.[][] | {type:6, request:{itemid:.itemid}}]') || return 0
    if [[ $ids != "[]" ]]; then api task.create "$ids" >/dev/null 2>&1 || true; fi
}

# ---------------------------------------------------------------------------
log "Místní host $ZBX_HOSTNAME (Debian 13, Zabbix Agent 2)"
LINUX_GID=$(group_id "Linux servers")
LAB_GID=$(group_id "$LAB_GROUP")

LINUX_TID=$(template_id "Linux by Zabbix agent")
[[ -n $LINUX_TID ]] || die "chybí šablona 'Linux by Zabbix agent'"
TEMPLATES=$(jq -cn --arg t "$LINUX_TID" '[{templateid:$t}]')
HEALTH_TID=$(template_id "Zabbix server health")
[[ -n $HEALTH_TID ]] && TEMPLATES=$(jq -c --arg t "$HEALTH_TID" '. + [{templateid:$t}]' <<<"$TEMPLATES")

LOCAL_HID=$(host_id "$ZBX_HOSTNAME")
if [[ -z $LOCAL_HID ]]; then
    LOCAL_HID=$(api host.create "$(jq -cn \
        --arg host "$ZBX_HOSTNAME" --arg g1 "$LINUX_GID" --arg g2 "$LAB_GID" --argjson t "$TEMPLATES" '{
            host: $host,
            name: ("Debian 13 – " + $host),
            groups: [{groupid:$g1}, {groupid:$g2}],
            templates: $t,
            interfaces: [{type:1, main:1, useip:1, ip:"127.0.0.1", dns:"", port:"10050"}],
            tags: [{tag:"os", value:"debian13"}, {tag:"school", value:"sposdk"}]
        }')" | jq -r '.hostids[0]')
    echo "Vytvořen host $ZBX_HOSTNAME (id $LOCAL_HID)"
else
    echo "Host $ZBX_HOSTNAME už existuje (id $LOCAL_HID)"
fi

# Výchozí host "Zabbix server" z instalace sleduje stejného agenta – vypneme ho,
# ať nejsou v Latest data dvě kopie stejných hodnot.
DEFAULT_HID=$(host_id "Zabbix server")
if [[ -n $DEFAULT_HID ]]; then
    api host.update "$(jq -cn --arg h "$DEFAULT_HID" '{hostid:$h, status:1}')" >/dev/null
    echo "Výchozí host 'Zabbix server' vypnut (nahrazen hostem $ZBX_HOSTNAME)"
fi

# ---------------------------------------------------------------------------
log "Host sposdk.cz – monitoring TLS certifikátu https://sposdk.cz"
CERT_TPL="Website certificate by Zabbix agent 2"
CERT_TID=$(template_id "$CERT_TPL")
[[ -n $CERT_TID ]] || die "chybí šablona '$CERT_TPL'"

CERT_HID=$(host_id "sposdk.cz")
if [[ -z $CERT_HID ]]; then
    [[ -f $EXPORT_FILE ]] || die "chybí $EXPORT_FILE (nahrává ho Vagrant file provisioner)"
    rules='{
        "host_groups":     {"createMissing": true, "updateExisting": false},
        "hosts":           {"createMissing": true, "updateExisting": false},
        "templateLinkage": {"createMissing": true, "deleteMissing": false}
    }'
    if api configuration.import "$(jq -cn --rawfile src "$EXPORT_FILE" --argjson r "$rules" \
            '{format:"yaml", source:$src, rules:$r}')" >/dev/null; then
        echo "Import $EXPORT_FILE proběhl"
    else
        # Záloha: kdyby import exportu selhal, vytvoříme stejného hosta přímo přes API
        echo "Import selhal – zakládám hosta sposdk.cz přímo přes API"
        WEB_GID=$(group_id "Web Certificate")
        api host.create "$(jq -cn --arg g "$WEB_GID" --arg t "$CERT_TID" '{
            host:"sposdk.cz", name:"sposdk.cz",
            groups:[{groupid:$g}], templates:[{templateid:$t}],
            interfaces:[{type:1, main:1, useip:1, ip:"127.0.0.1", dns:"", port:"10050"}],
            macros:[{macro:"{$CERT.WEBSITE.HOSTNAME}", value:"sposdk.cz",
                     description:"The website DNS name for the connection."}],
            inventory_mode:1
        }')" >/dev/null
    fi
    CERT_HID=$(host_id "sposdk.cz")
    [[ -n $CERT_HID ]] || die "host sposdk.cz se nepodařilo vytvořit"
else
    echo "Host sposdk.cz už existuje (id $CERT_HID)"
fi

# Pojistky: host musí mít šablonu, makro a být i ve skupině SPOŠ DK Lab
info=$(api host.get "$(jq -cn --arg h "$CERT_HID" '{hostids:[$h], output:["hostid"],
        selectParentTemplates:["templateid"], selectMacros:["macro","value"], selectHostGroups:["groupid"]}')")
if ! jq -e --arg t "$CERT_TID" '.[0].parentTemplates | any(.templateid == $t)' >/dev/null <<<"$info"; then
    api host.massadd "$(jq -cn --arg h "$CERT_HID" --arg t "$CERT_TID" '{hosts:[{hostid:$h}], templates:[{templateid:$t}]}')" >/dev/null
    echo "Připojena šablona $CERT_TPL"
fi
if ! jq -e '.[0].macros | any(.macro == "{$CERT.WEBSITE.HOSTNAME}")' >/dev/null <<<"$info"; then
    api usermacro.create "$(jq -cn --arg h "$CERT_HID" '{hostid:$h, macro:"{$CERT.WEBSITE.HOSTNAME}", value:"sposdk.cz"}')" >/dev/null
    echo "Doplněno makro {\$CERT.WEBSITE.HOSTNAME}=sposdk.cz"
fi
if ! jq -e --arg g "$LAB_GID" '.[0].hostgroups | any(.groupid == $g)' >/dev/null <<<"$info"; then
    api host.massadd "$(jq -cn --arg h "$CERT_HID" --arg g "$LAB_GID" '{hosts:[{hostid:$h}], groups:[{groupid:$g}]}')" >/dev/null
fi

# Ať jsou data v Latest data hned a nečeká se na první interval
check_now "$LOCAL_HID"
check_now "$CERT_HID"

# ---------------------------------------------------------------------------
if [[ ! -s $ADMIN_FILE ]]; then
    log "Výchozí heslo Admin -> náhodné heslo"
    install -d -m 700 "$SECRET_DIR"
    NEW_PASS=$(openssl rand -hex 16)
    ADMIN_ID=$(api user.get '{"output":["userid"],"filter":{"username":["Admin"]}}' | jq -r '.[0].userid')
    api user.update "$(jq -cn --arg id "$ADMIN_ID" --arg new "$NEW_PASS" --arg old "$ADMIN_PASS" \
        '{userid:$id, passwd:$new, current_passwd:$old}')" >/dev/null
    ( umask 077; printf '%s\n' "$NEW_PASS" > "$ADMIN_FILE" )
    echo "Nové heslo je ve VM v $ADMIN_FILE"
fi

# ---------------------------------------------------------------------------
log "Rychlá kontrola agenta"
echo -n "agent.version:      "; zabbix_get -s 127.0.0.1 -k agent.version
echo -n "system.hostname:    "; zabbix_get -s 127.0.0.1 -k system.hostname
echo -n "certifikát sposdk:  "
zabbix_get -s 127.0.0.1 -k 'web.certificate.get[sposdk.cz]' \
  | jq -r '"platí do " + .x509.not_after.value + " – " + .result.message' 2>/dev/null \
  || echo "nedostupné (zkontroluj DNS/síť VM)"

log "Hotovo"
cat <<EOF
Web:      http://127.0.0.1:8080/zabbix/
Login:    Admin
Heslo:    vagrant ssh -c 'sudo cat $ADMIN_FILE'
EOF
