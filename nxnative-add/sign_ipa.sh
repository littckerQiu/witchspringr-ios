#!/bin/bash
# Sign the IPA with the player's certificate, so the artifact that gets downloaded is already installable.
#
#   SIGN_P12          base64 of the .p12 (certificate + private key)      [repository secret]
#   SIGN_PROFILE      base64 of the .mobileprovision                     [repository secret]
#   SIGN_PASSWORD     the .p12 password                                  [repository secret]
#   SIGN_BUNDLE_ID    the App ID the profile allows, e.g. app.snow8459.moonstone4810
#
# The profile this port was set up with carries an explicit App ID (no wildcard), so the bundle identifier must be
# rewritten to it: zsign -b does that while signing, and every future build then uses the same identifier, so the app's
# Documents folder (the game data) survives updates after the first signed install.
set -u
IPA=${1:-/tmp/WitchSpringR.ipa}
WORK=${WORK:-/tmp/sign}

if [ -z "${SIGN_P12:-}" ] || [ -z "${SIGN_PROFILE:-}" ]; then
    echo "no signing certificate in the repository secrets: the IPA stays unsigned"
    exit 0
fi

mkdir -p "$WORK" || exit 1
cd "$WORK" || exit 1
printf '%s' "$SIGN_P12" | base64 -d > cert.p12 || exit 1
printf '%s' "$SIGN_PROFILE" | base64 -d > profile.mobileprovision || exit 1
printf '%s' "${SIGN_PASSWORD:-}" > pw.txt

if [ ! -x "$WORK/zsign" ]; then
    rm -rf zsrc
    git clone --depth 1 https://github.com/zhlynn/zsign.git zsrc || { echo "cannot fetch zsign, leaving the IPA unsigned"; exit 0; }
    ( cd zsrc/build/linux && make -j4 ) || { echo "zsign did not build, leaving the IPA unsigned"; exit 0; }
    cp zsrc/bin/zsign "$WORK/zsign" || exit 1
fi

OUT="${IPA%.ipa}-signed.ipa"
BUNDLE_ARGS=()
[ -n "${SIGN_BUNDLE_ID:-}" ] && BUNDLE_ARGS=(-b "$SIGN_BUNDLE_ID")   # the profile's App ID, when it is not a wildcard
"$WORK/zsign" -k cert.p12 -p "$(cat pw.txt)" -m profile.mobileprovision "${BUNDLE_ARGS[@]}" \
             -z 1 -o "$OUT" "$IPA" 2>&1 | tail -8

if [ -s "$OUT" ]; then
    mv "$OUT" "$IPA"
    echo "signed: $(ls -l "$IPA" | awk '{print $5}') bytes, bundle id ${SIGN_BUNDLE_ID:-unchanged}"
else
    echo "signing produced no output, the unsigned IPA is kept"
fi
