vgate_name census-device "fixture: D1 device ineligibility (share + flag)"
vgate_share seed
vgate_run s1 -- --script s1.txt --timeout 60
vgate_run s2 -- --timeout 60
