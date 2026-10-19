vgate_name census-device-flag "fixture: per-leg D1 flags incl. backslash-joined run"
vgate_run f1 -- \
    --cvc-echo \
    --timeout 60
vgate_run f2 -- --script s.txt --timeout 60
