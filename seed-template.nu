export def seed-prompt [record: record] {
  $"You will receive one JSON object describing a token.
Return the same object with missing fields filled in.
Do not add prose.
Do not add extra keys.
If uncertain, use null and set confidence to \"guessing\".
If confident, set confidence to \"sure\".
`paa_root` and `paa_guesses` must be tuples of [root, gloss].

Input record: (($record | to json))"
}

export def token-seed-schema [] {
  {
    allowed: [
      "idx_form"
      "surface"
      "detected_root"
      "paa_root"
      "paa_guesses"
      "association_types"
      "phenomenological_association"
      "context"
      "source"
      "confidence"
      "note"
    ]
    required: [
      "surface"
      "confidence"
    ]
    non_null: [
      "surface"
      "confidence"
    ]
  }
}

export def token-seed-input [token: record] {
  let cols = ($token | columns)
  let surface = if ($cols | any { |c| $c == "surface" }) {
    $token.surface
  } else if ($cols | any { |c| $c == "idx_form" }) {
    $token.idx_form
  } else {
    null
  }

  {
    idx_form: ($token.idx_form? | default null)
    surface: $surface
    detected_root: ($token.detected_root? | default null)
    paa_root: ($token.paa_root? | default null)
    paa_guesses: ($token.paa_guesses? | default [])
    association_types: ($token.association_types? | default [])
    phenomenological_association: ($token.phenomenological_association? | default null)
    context: ($token.context? | default null)
    source: ($token.source? | default {
      volume: ($token.volume? | default null)
      book: ($token.book? | default null)
      chapter: ($token.chapter? | default null)
      verse: ($token.verse? | default null)
    })
    confidence: ($token.confidence? | default "guessing")
    note: ($token.note? | default null)
  }
}
