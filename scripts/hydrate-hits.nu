def main [hits-path: string, limit: int = 5] {
  open $hits-path | from json | each { |h| $h } | to nuon > /tmp/hits.nuon

  # iterate and pick first occurrence per id
  let unique = (open /tmp/hits.nuon | from nuon | group-by id | each { get 1 | nth 0 } | first $limit)

  $unique | each { |hit|
    open data/nu_docs.msgpack | from msgpack | where id == $hit.id and idx == $hit.idx | insert score $hit.score
  } | flatten
}

main $env.HITS_PATH $env.LIMIT
