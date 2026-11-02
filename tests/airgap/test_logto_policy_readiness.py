"""Exercise the deploy seeder with delayed/missing DB and absent Hub containers."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'unified/scripts/deploy.sh').read_text()
START = SOURCE.index('seed_ee() {')
FUNCTION = SOURCE[START:SOURCE.index('\n}\n', START) + 3]

STUBS = r'''
set -euo pipefail
STACK=target
PROJECT=target-project
HERE=/repo/unified
ENV=prod
sleep() { :; }
docker() {
  case "$*" in
    *industream-hub-backend*) return 0 ;;
    *logto-postgres*) echo target-db ;;
    *pg_isready*)
      if [[ "$READY" != true ]]; then return 1; fi
      if [[ ! -f "$STATE/attempted" ]]; then touch "$STATE/attempted"; return 1; fi
      touch "$STATE/ready" ;;
    *) echo "unexpected Docker call: $*" >&2; return 1 ;;
  esac
}
bash() {
  [[ -f "$STATE/ready" ]] || { echo 'policy called before readiness' >&2; return 1; }
  printf '%s\n' "$*" > "$STATE/policy"
}
'''

class PolicyReadiness(unittest.TestCase):
    def check_case(self, runtime, airgap, ready, expected):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, STATE=directory, RUNTIME=runtime,
                       AIRGAP=airgap, READY=ready)
            result = subprocess.run(['bash', '-c', STUBS + FUNCTION + '\nseed_ee'],
                                    env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            policy = Path(directory) / 'policy'
            self.assertEqual(policy.exists(), expected, result.stdout + result.stderr)
            if expected:
                self.assertEqual(policy.read_text().strip(),
                    '/repo/unified/../scripts/setup/logto-airgap-password-policy.sh --container target-db')

    def test_swarm_waits_and_applies_without_hub(self):
        self.check_case('swarm', 'true', 'true', True)

    def test_compose_uses_target_database(self):
        self.check_case('compose', 'true', 'true', True)

    def test_online_preserves_check(self):
        self.check_case('swarm', 'false', 'true', False)

    def test_unavailable_database_is_not_modified(self):
        self.check_case('swarm', 'true', 'false', False)

if __name__ == '__main__':
    unittest.main()
