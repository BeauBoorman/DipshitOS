vgate_name census-adopted "fixture: adopted warm legs on a saveable share"
vgate_share arm-virtiofs
vgate_checkpoint ck -- --timeout 60
vgate_run w1 --from-checkpoint ck -- --script s1.txt --timeout 60
vgate_run w2 --from-checkpoint ck -- --script s2.txt --timeout 60
vgate_run c1 -- --expect 'boot banner' --script s3.txt
# warm-cold: c2 (f) leg c2 reads the share file c1 wrote — sibling-leg dependence
vgate_run c2 -- --script s4.txt --timeout 60
