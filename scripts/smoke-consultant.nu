#!/usr/bin/env nu
# Smoke test for the Consultant contract adapter (agent/consultant.nu).
#
# Run from repo root:         nu scripts/smoke-consultant.nu
# Or from inside scripts/:    nu smoke-consultant.nu
#
# Exercises: consult --role X --prompt Y → prose synthesis over simulated
# deterministic data. The data stands in for what an Operator invocation
# would have produced upstream.

use ../agent/consultant.nu *

# Simulated "deterministic output from a prior Operator run" — exactly the
# kind of structured data a Consultant is supposed to synthesise over.
let deterministic_data = {
  user: "michael"
  period: "last 7 days"
  workouts: [
    { day: "Mon", type: "strength", duration_min: 45 }
    { day: "Wed", type: "cardio",   duration_min: 30 }
    { day: "Fri", type: "strength", duration_min: 50 }
    { day: "Sat", type: "mobility", duration_min: 20 }
  ]
  total_min: 145
}

let prompt = $"Given the workout data below, briefly describe the balance of training types this week and give one piece of advice.\n\nData: (($deterministic_data | to json))"

print "Calling consult \(role=Fitness-Coach\) ..."
print "---"

let response = (consult --role "Fitness-Coach" --prompt $prompt)

print "Response:"
print $response
print "---"

# Loose validation: response should be prose (not JSON/tool-calls), non-trivial
# length, and reasonably on-topic given the simulated data.
let first_char = (try { ($response | str substring 0..1) } catch { "" })
if (($response | str length) < 40) {
  print "smoke: FAIL — response too short"
  exit 1
} else if ($first_char == "[") or ($first_char == "{") {
  print "smoke: FAIL — response looks like JSON/tool-calls, not prose"
  exit 1
} else {
  let resp_lower = ($response | str downcase)
  if ($resp_lower | str contains "strength") or ($resp_lower | str contains "cardio") or ($resp_lower | str contains "mobility") or ($resp_lower | str contains "workout") {
    print "smoke: OK"
  } else {
    print "smoke: UNEXPECTED — response is prose but did not mention expected keywords; review manually"
  }
}
