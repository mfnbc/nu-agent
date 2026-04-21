def merge_and_reconcile [--transactions: string, --ledger: string, --out: string] {
  # Default paths
  let tx = ($transactions | default "transactions.csv")
  let ledger_path = ($ledger | default "ledger.nuon")
  let out = ($out | default "ledger_reconciled.nuon")

  # Read transactions CSV - expect columns: date, amount, description
  let tx_table = (open $tx | from csv)

  # Read ledger nuon (assumed a table of {date, amount, description, reconciled})
  let ledger = (open $ledger_path | from nuon)

  # Annotate transactions with parsed date for comparison
  let tx_parsed = $tx_table | each { |r| merge $r { parsed_date: (echo $r.date | str to datetime) } }

  let ledger_parsed = $ledger | each { |r| merge $r { parsed_date: (echo $r.date | str to datetime), reconciled: ($r.reconciled? | default false) } }

  # For each transaction, find exact amount matches in ledger and pick the closest date within 7 days
  let reconciled = $ledger_parsed | each { |l|
    if $l.reconciled == true {
      $l
    } else {
      let candidates = ($tx_parsed | where { |t| ($t.amount == $l.amount) })
      if ($candidates | length) == 0 {
        $l
      } else {
        # compute min abs(date difference)
        let best = $candidates | sort-by { |c| (|((($c.parsed_date - $l.parsed_date) | math abs))|) } | first
        let days = ((($best.parsed_date - $l.parsed_date) | math abs) / 86400)
        if $days <= 7 {
          merge $l { reconciled: true, reconciled_on: $best.date, reconciled_note: $best.description }
        } else {
          $l
        }
      }
    }
  }

  # Write updated ledger back to nuon
  ($reconciled | to nuon) > $out
  print --stderr "Wrote reconciled ledger to: ($out)"
}

export def main [] {
  # convenience wrapper for CLI usage
  merge_and_reconcile
}
