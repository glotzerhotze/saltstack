#!/bin/sh
# Managed by Salt (apt_keyrings formula) - do not edit.
#
#   keyring.sh install  NAME FORMAT FPRS DIGESTS SRC DST
#       Verify SRC and write it to DST atomically, root:root 0644.
#   keyring.sh uptodate NAME FORMAT FPRS DIGESTS SRC DST
#       Exit 0 if SRC still verifies and DST already is exactly what
#       "install" would write (content, owner and mode).
#
#   FORMAT  binary   - DST is a binary keyring; armored SRC is dearmored
#           verbatim - DST is a byte-for-byte copy of SRC
#   FPRS    comma-separated primary key fingerprints, or "-" for no pinning.
#           With pinning, the set of primary keys in SRC must be EXACTLY this
#           set: an extra key in the download fails too.
#   DIGESTS strict     - reject keys that apt's sqv verifier (Debian 13+)
#                        would treat as unbound: see weak_bindings() below
#           allow-weak - skip that check (for hosts still verifying with gpgv)
set -eu

ARMOR_HEADER='-----BEGIN PGP PUBLIC KEY BLOCK-----'

# Digests apt's sqv policy still accepts for binding signatures:
# SHA-256, SHA-384, SHA-512, SHA3-256, SHA3-512. Everything else - notably
# SHA-1 and SHA-224, rejected since 2026-02-01 - does not bind a key.
STRONG_DIGESTS=' 8 9 10 12 14 '

die() { echo "apt_keyrings: key '$name': $*" >&2; exit 1; }

is_armored() { grep -q -- "$ARMOR_HEADER" "$1"; }

# Primary key fingerprints in $1, one per line, sorted. Imports nothing.
primary_fprs() {
    h=$(mktemp -d)
    # In --with-colons output, the "fpr" record right after "pub" is the
    # primary key; "fpr" records after "sub" belong to subkeys.
    GNUPGHOME=$h gpg --batch --quiet --show-keys --with-colons "$1" 2>/dev/null \
        | awk -F: '$1 == "pub" { p = 1; next }
                   $1 == "fpr" && p { print toupper($10) }
                   { p = 0 }' \
        | sort -u || true
    rm -rf "$h"
}

# Print one line per key component in $1 that has no binding signature with
# a strong digest; print nothing if the file is fine. Mirrors what sqv needs:
#   - every primary key: a self-signature over a user ID (0x10-0x13) or a
#     direct-key self-signature (0x1f) with a strong digest
#   - every signing subkey that is neither expired nor revoked: a subkey
#     binding signature (0x18) with a strong digest whose embedded primary
#     key binding signature (0x19, made by the subkey) is strong as well
# Encryption-only, expired and revoked subkeys are ignored, as sqv ignores
# them; old vendor keys often carry such leftovers bound with SHA-1.
weak_bindings() {
    h=$(mktemp -d)
    GNUPGHOME=$h gpg --batch --quiet --show-keys --with-colons "$1" \
        > "$h/colons" 2>/dev/null || true
    GNUPGHOME=$h gpg --batch --quiet --list-packets "$1" \
        > "$h/packets" 2>/dev/null || true
    awk -v strong="$STRONG_DIGESTS" '
        function isstrong(d) { return d != "" && index(strong, " " d " ") > 0 }
        function dname(d) {
            if (d == "")  return "none"
            if (d == 1)   return "MD5"
            if (d == 2)   return "SHA-1"
            if (d == 3)   return "RIPEMD-160"
            if (d == 11)  return "SHA-224"
            return "digest algo " d
        }
        function flush() {
            if (!insig || signer != pk) { insig = 0; return }
            if ((comp == "pub" || comp == "uid") && (cls ~ /^0x1[0-3]$/ || cls == "0x1f")) {
                if (isstrong(dg)) okp[pk] = 1; else seenp[pk] = seenp[pk] " " dname(dg)
            }
            if (comp == "sub" && cls == "0x18") {
                if (isstrong(dg) && isstrong(bdg)) oks[sk] = 1
                else if (!isstrong(dg)) seens[sk] = seens[sk] " binding " dname(dg)
                else seens[sk] = seens[sk] " back-signature " dname(bdg)
            }
            insig = 0
        }
        FNR == 1 { file++ }

        # pass 1, --with-colons: which subkeys are live signing subkeys
        file == 1 {
            n = split($0, f, ":")
            if (f[1] == "pub") pkc = f[5]
            if (f[1] == "sub" && f[2] !~ /[er]/ && f[12] ~ /s/) signsub[f[5]] = pkc
            next
        }

        # pass 2, --list-packets: digests of all self-signatures
        /^# off=/                { next }
        /^:/                     { flush() }
        /^:public key packet:/   { comp = "pub"; want = "pk"; next }
        /^:public sub key packet:/ { comp = "sub"; want = "sk"; next }
        /^:(user ID|attribute) packet:/ { comp = "uid"; next }
        /^:signature packet:/    { insig = 1; signer = $NF; cls = dg = bdg = ""; next }
        /^:/                     { next }
        $1 == "keyid:" {
            if (want == "pk") { pk = $2; prim[pk] = 1 } else if (want == "sk") sk = $2
            want = ""; next
        }
        insig && /sigclass/                     { cls = $NF }
        insig && /^[ \t]*digest algo/           { dg = $3 + 0 }
        insig && /subpkt 32 / && /class 0x19/   { d = $NF; gsub(/[^0-9]/, "", d); bdg = d }

        END {
            flush()
            for (k in prim)
                if (!okp[k])
                    printf "primary key %s is bound only by weak signatures (%s)\n", k, substr(seenp[k], 2)
            for (k in signsub)
                if (!oks[k])
                    printf "signing subkey %s of %s is bound only by weak signatures (%s)\n", k, signsub[k], substr(seens[k], 2)
        }
    ' "$h/colons" "$h/packets" || rc=$?
    rm -rf "$h"
    return "${rc:-0}"
}

verify() {  # SRC
    actual=$(primary_fprs "$1")
    [ -n "$actual" ] || die "download is not an OpenPGP public key ($1)"
    if [ "$fprs" != - ]; then
        expected=$(printf '%s\n' "$fprs" | tr ',' '\n' | tr 'abcdef' 'ABCDEF' \
                   | grep -v '^$' | sort -u)
        [ "$actual" = "$expected" ] || die "fingerprint mismatch
  expected: $(printf '%s' "$expected" | tr '\n' ' ')
  found:    $(printf '%s' "$actual" | tr '\n' ' ')"
    fi
    if [ "$digests" = strict ]; then
        weak=$(weak_bindings "$1") || die "could not inspect the key's signatures"
        [ -z "$weak" ] || die "apt's sqv verifier (Debian 13+) will reject this key:
$(printf '%s\n' "$weak" | sed 's/^/  /')
  Get a copy of the key re-signed with SHA-256 or better from the vendor,
  or set 'allow_weak_digests: true' for this key if all hosts use gpgv."
    fi
}

render() {  # SRC DST -> stdout
    case $format in
    binary)
        if is_armored "$1"; then gpg --batch --dearmor < "$1"; else cat "$1"; fi
        ;;
    verbatim)
        # apt decides armored vs. binary by the file extension alone
        case $2 in
        *.asc) is_armored "$1" || die "download is binary, but '$2' ends in .asc" ;;
        *)     is_armored "$1" && die "download is armored: use '.asc' or dearmor: true" ;;
        esac
        cat "$1"
        ;;
    *) die "unknown format '$format'" ;;
    esac
}

USAGE="usage: $0 {install|uptodate} NAME FORMAT FPRS DIGESTS SRC DST"
[ $# -eq 7 ] || { echo "$USAGE" >&2; exit 2; }
cmd=$1 name=$2 format=$3 fprs=$(printf '%s' "$4" | tr -d ' \t') digests=$5 src=$6 dst=$7
case $digests in
strict|allow-weak) ;;
*) echo "$USAGE" >&2; exit 2 ;;
esac

case $cmd in
install)
    verify "$src"
    tmp=$(mktemp "$dst.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    render "$src" "$dst" > "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dst"
    trap - EXIT
    echo "installed $dst"
    ;;
uptodate)
    [ "$(stat -c '%a:%U:%G' "$dst" 2>/dev/null)" = '644:root:root' ] || exit 1
    ( verify "$src" ) 2>/dev/null || exit 1
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    ( render "$src" "$dst" ) > "$tmp" 2>/dev/null || exit 1
    cmp -s "$tmp" "$dst"
    ;;
*)
    echo "$USAGE" >&2
    exit 2
    ;;
esac
