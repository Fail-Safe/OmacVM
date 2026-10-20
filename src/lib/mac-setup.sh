# What an OmacVM VM needs from the Mac it runs on (sourced after mac.sh and
# features.sh; macOS's bash 3.2). One map of features to Mac helpers for
# omacvm apply (what it installs), omacvm check and OmacVM.app.
#   mac_helper_of FEATURE   MAC_HELPER: the helper it needs ("": none). TYPE:
#                           the VM's route (the Bridge serves UTM and Fusion
#                           VMs the Mac's battery and camera)
#   mac_helpers_needed      MAC_NEEDED: "|NAME|NAME|", the helpers of the
#                           features on in FV (features_fix first)
#   mac_needs NAME          true when MAC_NEEDED has it
#   mac_token_hash FILE     a Bridge token's short hash (16 hex)
#   mac_setup_write DIR TOKEN_FILE
#                           DIR/mac-setup: the VM in DIR has that token
#
# A VM folder copied from another Mac has the other Mac's token. DIR/mac-setup
# ("token <hash>", written by omacvm apply) says which Mac's token the VM has:
# a Mac moved with Migration Assistant keeps its token, so its VMs count as
# set up for it.
MAC_SETUP_FILE=mac-setup

mac_helper_of() {   # FEATURE
  MAC_HELPER=""
  case $1 in
    bridge|control-centre) MAC_HELPER="OmacVM Bridge" ;;   # the control centre asks the Mac through it
    camera|battery) [[ ${TYPE:-} == utm || ${TYPE:-} == fusion ]] && MAC_HELPER="OmacVM Bridge" ;;
    gestures|scroll-momentum) MAC_HELPER="OmacVM Gestures" ;;
    omanotch) MAC_HELPER=Omanotch ;;
  esac
  return 0
}

mac_helpers_needed() {
  local i
  MAC_NEEDED="|"
  for ((i = 0; i < ${#FN[@]}; i++)); do
    [[ ${FV[$i]:-} == on ]] || continue
    mac_helper_of "${FN[$i]}"
    if [[ -n $MAC_HELPER && $MAC_NEEDED != *"|$MAC_HELPER|"* ]]; then MAC_NEEDED+="$MAC_HELPER|"; fi
  done
  return 0
}

mac_needs() { [[ $MAC_NEEDED == *"|$1|"* ]]; }

mac_token_hash() {   # FILE: nothing and status 1 without a token
  local t
  t=$(tr -d '[:space:]' < "$1" 2>/dev/null) || return 1
  [[ -n $t ]] || return 1
  printf 'omacvm-bridge-token\n%s' "$t" | shasum -a 256 | cut -c1-16
}

mac_setup_write() {   # DIR TOKEN_FILE
  local h
  h=$(mac_token_hash "$2") || return 1
  printf 'token %s\n' "$h" > "$1/$MAC_SETUP_FILE.new" && mv -f "$1/$MAC_SETUP_FILE.new" "$1/$MAC_SETUP_FILE"
}
