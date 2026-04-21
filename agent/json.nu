# Shared JSON helpers for nu-agent modules

export def coerce-json [raw] {
  let t = ($raw | describe)

  if ($t | str starts-with "string") {
    $raw | from json
  } else {
    $raw
  }
}
