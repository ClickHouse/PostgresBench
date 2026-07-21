#!/bin/bash -e

echo "const data = [" > data.generated.js.new
FIRST=1
LANG="" ls -1 */results/*.json | while read -r file
do
    [[ $file =~ ^(hardware|versions|gravitons)/ ]] && continue;

    [ "${FIRST}" = "0" ] && echo -n ','
    jq --compact-output '
      . += {"source": $src}
      | if .region then . elif .aws_region then .region = .aws_region | del(.aws_region)
        elif ($src | test("_us-west-2\\.json$")) then . + {"region": "us-west-2"}
        else . + {"region": "us-east-2"}
        end
      | if .cloud then . else . + {"cloud": "aws"} end
      | del(.aws_region)
      | if .ha then .
        else . + {"ha": {"label": "No HA", "mode": "off", "standbys": 0, "live_settings": null}}
        end
      | .ha_label = .ha.label
    ' --arg src "${file}" "${file}" || echo "Error in $file" >&2
    FIRST=0
done >> data.generated.js.new
echo '];' >> data.generated.js.new

mv data.generated.js data.generated.js.bak
mv data.generated.js.new data.generated.js
