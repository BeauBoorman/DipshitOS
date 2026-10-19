vgate_name census-bad-class "fixture: declaration class outside a-f"
# warm-cold: 01 (g) not a real class
vgate_run 01 -- --script s.txt --timeout 60
