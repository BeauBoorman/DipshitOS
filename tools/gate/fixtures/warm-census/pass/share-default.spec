vgate_name census-share-default "fixture: \${VAR:-default} share resolves to seed"
vgate_share ${CENSUS_SHARE:-seed}
vgate_run d1 -- --script s.txt --timeout 60
