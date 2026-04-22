source ../agent/enrichment.nu
source ../api.nu

let record = (open /tmp/record.json)
let schema = { allowed: ['answer'], required: ['answer'], non_null: ['answer'] }
let prompt = (enrichment-prompt 'explain how to point the agent to a local LM Studio instance' $record $schema)
let system = (enrichment-system-prompt)

let body = {
  model: ($env.NU_AGENT_MODEL? | default 'qwen/qwen3.5-35b-a3b'),
  temperature: 0,
  top_p: 1,
  messages: [ { role: 'system', content: $system } { role: 'user', content: $prompt } ]
} | to json

$body | save /tmp/body.json
echo saved /tmp/body.json
