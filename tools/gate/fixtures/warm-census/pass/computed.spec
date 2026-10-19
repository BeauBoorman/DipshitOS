vgate_name census-computed "fixture: computed D7 classes from flags and asserts"
vgate_run a1 -- --expect 'settled' --script s1.txt --timeout 60
vgate_run a2 -- --script s2.txt --timeout 60
vgate_run b1 -- --vz-restore-state '$RUN_DIR/save' --timeout 60
vgate_run b2 -- --resume --script s3.txt
vgate_run c1 -- --console-tcp 8023 --timeout 60
vgate_run c2 -- --input-string 'hi' --input-string-after 'prompt'
vgate_run c3 -- --net-inject '$RUN_DIR/f.bin' --timeout 60
vgate_run e1 -- --usb-msd '$RUN_DIR/usb.img' --timeout 60
vgate_run e2 -- --host-cmd-after 'echo ping' --timeout 60
vgate_run e3 -- --profile '$RUN_DIR/prof' --timeout 60
vgate_assert a2 serial-contains 'kern: map init ok'
vgate_assert e1 serial-contains 'VirelaiOS kernel has seized control.'
