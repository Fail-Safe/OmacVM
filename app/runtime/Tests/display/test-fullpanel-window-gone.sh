#!/bin/bash
# FullPanel's state lets go of a window that is freed (#402,
# omacvm-cocoa-fullpanel-window-gone.patch), checked in the patched ui/cocoa.m:
#   - the state hangs on its window through OmacVMFullPanelOwner, which only
#     the window's association holds, and omacvm_fullpanel_state reads it there;
#   - the owner's dealloc tells the state (windowGone) before releasing it;
#   - windowGone forgets the window first, then stops observing and shows the
#     menu bar; the state's own dealloc never asks the window anything first;
#   - with --self-test (CI): the checks fail on the code without the patch.
#   test-fullpanel-window-gone.sh <patched ui/cocoa.m> | --self-test
set -uo pipefail
body() { awk -v h="$2" '$0 == h {on=1} on {print} on && /^}$/ {exit}' "$1"; }
problems() {
  local m=$1 prep get gone dealloc owner
  prep=$(body "$m" 'static void omacvm_fullpanel_prepare_window(NSWindow *window)')
  get=$(body "$m" 'static OmacVMFullPanelState *omacvm_fullpanel_state(NSWindow *window)')
  [[ -n $prep && -n $get ]] || { echo "no FullPanel state"; return; }
  grep -q '^@interface OmacVMFullPanelOwner : NSObject' "$m" || echo "no owner between window and state"
  grep -q 'objc_setAssociatedObject(window, &omacvm_fullpanel_state_key, owner,' <<<"$prep" ||
    echo "the window holds its state directly"
  grep -q 'owner->state = \[\[OmacVMFullPanelState alloc\] initWithWindow:window\];' <<<"$prep" ||
    echo "the owner does not hold the state"
  grep -q 'return owner ? owner->state : nil;' <<<"$get" || echo "the state is not read through its owner"
  owner=$(awk '/^@implementation OmacVMFullPanelOwner/{on=1} on{print} on && /^@end/{exit}' "$m")
  awk '/\[state windowGone\];/{g=NR} /\[state release\];/{r=NR} END{exit !(g && r && g < r)}' <<<"$owner" ||
    echo "the owner does not tell the state before letting it go"
  gone=$(body "$m" '- (void)windowGone')
  [[ -n $gone ]] || { echo "no windowGone"; return; }
  awk 'NR > 2 && !/^ *$/ && !s {s=NR; first=$0} END{exit !(first ~ /window = nil;/)}' <<<"$gone" ||
    echo "windowGone does not forget the window first"
  grep -q '\[\[NSNotificationCenter defaultCenter\] removeObserver:self\];' <<<"$gone" &&
    grep -q '\[self showMenuBar\];' <<<"$gone" || echo "windowGone does not stop observing and show the menu bar"
  dealloc=$(awk '/^@implementation OmacVMFullPanelState/{on=1} on && index($0, "- (void)dealloc") == 1 {d=1} d {print} d && /^}$/ {exit}' "$m")
  grep -q '\[window ' <<<"$dealloc" && echo "the state's dealloc asks the window"
}
if [[ ${1:-} == --self-test ]]; then
  T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-fullpanel-window-gone.XXXXXX")
  trap 'rm -rf "$T"' EXIT
  cat > "$T/old.m" <<'EOF'
static OmacVMFullPanelState *omacvm_fullpanel_state(NSWindow *window)
{
    return window ? objc_getAssociatedObject(window, &omacvm_fullpanel_state_key) : nil;
}
static void omacvm_fullpanel_prepare_window(NSWindow *window)
{
    OmacVMFullPanelState *state = [[OmacVMFullPanelState alloc] initWithWindow:window];
    objc_setAssociatedObject(window, &omacvm_fullpanel_state_key, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [state release];
}
EOF
  if [[ -n $(problems "$T/old.m") ]]; then echo "ok   the checks fail on the code without the patch"; exit 0; fi
  echo "FAIL the checks pass on the code without the patch" >&2; exit 1
fi
m=${1:?usage: test-fullpanel-window-gone.sh <patched ui/cocoa.m> | --self-test}
out=$(problems "$m")
if [[ -n $out ]]; then echo "test-fullpanel-window-gone: $m: $out" >&2; exit 1; fi
echo "test-fullpanel-window-gone: $m: wiring ok"
