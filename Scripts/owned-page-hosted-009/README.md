# Held hosted009 packet

Concrete source-only successor for the accepted SDK008 owned-page qualification. Read `PROPOSAL.md` for scope, exact inputs, preserved limits, current SDK coverage and remaining admission gates. `hosted.yml` is disabled; this packet is not installed or dispatched.

The only hosted entry is `hosted.py --root <fresh-run-root> --packet-seal-sha256 <reviewed-seal> --admission-sha256 <exact-JSON-hash>`. It requires exact hosted metadata and the root-approved admission file before launch. The native compiler/test commands remain the original SDK008 commands with the one owned-root substitution.

Run source-only tests with `python3 -B -m unittest -v test_preparation test_build_proof_005 test_lifecycle test_hosted`. Temporary test files stay in this packet's `pure-tmp` and are removed by each test. `prepare_packet.py` is the retained local assembly record, not a hosted entry; historical paths inside `evidence/sdk008` are data only.
