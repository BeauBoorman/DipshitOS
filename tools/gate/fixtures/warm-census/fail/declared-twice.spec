vgate_name census-declared-twice "fixture: same leg declared twice"
# warm-cold: 01 (a) first reason
vgate_run 01 -- --script s.txt --timeout 60
# warm-cold: 01 (d) second reason
