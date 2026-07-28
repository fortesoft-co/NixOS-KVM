# Shared summary fragment for the boot-test diff harnesses. Appended after the
# base 20 checks (+ any test extras) by mkDiffHarness. Reports the pass/fail
# count and exits non-zero on any failure. PASS/FAIL are defined in the base
# fragment (in scope via concatenation).
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
echo "OK: all checks passed."