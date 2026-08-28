#!/bin/sh
# Which capture path micd's init script chooses.
#
# select_capture_path() decides whether the microphone stream runs through the
# mux or straight out of the codec. Getting it wrong is expensive and quiet:
# picking the mux when it is not there leaves the device with no capture at
# all, and picking the codec when the mux is wanted silently disables audio
# injection, which is how the voice tests feed the device.
#
# The function is extracted from the real init script rather than copied, so
# this tests the text that ships. Running the script directly is not an option
# -- it would start the daemon.
set -eu

INIT=init/libreecho-micd.init
[ -f "$INIT" ] || { echo "missing $INIT"; exit 1; }

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT INT TERM

# The defaults the function depends on, then the function itself.
sed -n '/^CAPTURE_MUX=/p;/^CAPTURE_BIN=/p;/^BYPASS_MUX=/p;/^MIC_INJECT_DIR=/p' \
    "$INIT" > "$dir/fn.sh"
sed -n '/^select_capture_path()/,/^}/p' "$INIT" >> "$dir/fn.sh"

if ! grep -q "^select_capture_path()" "$dir/fn.sh"; then
    echo "FAIL: could not extract select_capture_path from $INIT"
    exit 1
fi

mux="$dir/capture-mux"
bin="$dir/tinycap"
flag="$dir/bypass-capture-mux"
printf '#!/bin/sh\n' > "$mux"; chmod +x "$mux"
printf '#!/bin/sh\n' > "$bin"; chmod +x "$bin"

choose() {
    CAPTURE_MUX=$mux CAPTURE_BIN=$bin BYPASS_MUX=$flag \
        MIC_INJECT_DIR="$dir/inject" sh -c ". $dir/fn.sh; select_capture_path"
}

# --- the mux is used when it is there ------------------------------------
got=$(choose)
if [ "$got" != "$mux" ]; then
    echo "FAIL: expected the mux, got $got"
    exit 1
fi
echo "  mux used when present: ok"

# --- and the codec when it is not ----------------------------------------
# A capture path that does not start is worse than losing injection.
chmod -x "$mux"
got=$(choose)
if [ "$got" != "$bin" ]; then
    echo "FAIL: expected the codec when the mux is not executable, got $got"
    exit 1
fi
echo "  codec used when the mux is missing: ok"
chmod +x "$mux"

# --- the bypass flag takes the mux out of the path -----------------------
# Clear the state an earlier mux run left behind, so what is checked below is
# what the bypass path did and not what a previous case did.
rm -rf "$dir/inject"
: > "$flag"
got=$(choose)
if [ "$got" != "$bin" ]; then
    echo "FAIL: bypass flag set but the mux was still chosen ($got)"
    exit 1
fi
echo "  bypass flag selects the codec: ok"

# The flag must not leave the mux half-configured: nothing downstream should
# see injection control state for a mux that is not in the path.
if [ -d "$dir/inject" ]; then
    echo "FAIL: the bypass path created the mux injection directory"
    exit 1
fi
echo "  bypass leaves no injection state: ok"

# --- and removing it restores the mux ------------------------------------
# The flag is a diagnostic, so it has to be reversible by deleting the file.
rm -f "$flag"
got=$(choose)
if [ "$got" != "$mux" ]; then
    echo "FAIL: removing the flag did not restore the mux ($got)"
    exit 1
fi
echo "  removing the flag restores the mux: ok"

# --- a directory at that path must not brick the device ------------------
# /data/libreecho/config tolerates unknown regular files but treats an unknown
# directory as a hard contract failure, which blocks every service at the next
# boot. The gate therefore tests for a file, not for existence.
rm -rf "$flag"; mkdir -p "$flag"
got=$(choose)
if [ "$got" != "$mux" ]; then
    echo "FAIL: a directory at the flag path was treated as the flag ($got)"
    exit 1
fi
echo "  a directory at the flag path is not the flag: ok"

echo "micd capture path: ok"
