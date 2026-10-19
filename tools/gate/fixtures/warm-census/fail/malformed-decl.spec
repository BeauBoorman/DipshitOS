vgate_name census-malformed-decl "fixture: declaration missing (class) group"
# warm-cold: 01 no class parens here
vgate_run 01 -- --script s.txt --timeout 60
