vgate_name census-declared-adopted "fixture: a cold declaration on a warm leg"
vgate_checkpoint ck -- --timeout 60
vgate_run 01 --from-checkpoint ck -- --script s.txt --timeout 60
# warm-cold: 01 (d) adopted legs cannot be declared cold
