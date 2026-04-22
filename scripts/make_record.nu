let ctx = (open build/rag/hydrated_top5.json | from json | get text | str join '\n\n')
echo $ctx | save /tmp/context.txt
$ctx | to json | save /tmp/record.json
echo saved
