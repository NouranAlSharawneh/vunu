#!/bin/zsh
# Reset Vunu's TCC grants (Accessibility + Microphone) so onboarding can be re-tested.
set -uo pipefail
tccutil reset Accessibility dev.nunu.vunu || true
tccutil reset Microphone dev.nunu.vunu || true
tccutil reset ListenEvent dev.nunu.vunu || true
echo "TCC reset for dev.nunu.vunu"
