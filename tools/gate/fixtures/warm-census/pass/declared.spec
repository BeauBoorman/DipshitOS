vgate_name census-declared "fixture: declared (a)/(d)/(f) and vgate_client (c)"
vgate_client cl1 -- --addr '127.0.0.1:24680' --after 'virelai>' --send 'uptime'
# warm-cold: t1 (a) leg asserts on boot banner the epoch hides
vgate_run t1 -- --script a.txt --timeout 60
# warm-cold: t2,t3 (d) wall-clock budget legs measure boot-to-prompt elapsed
vgate_run t2 -- --script b.txt --timeout 60
vgate_run t3 -- --script c.txt --timeout 60
vgate_run cl1 -- --script d.txt --timeout 60
# a declaration can only exclude — t1's device-clean status doesn't matter
