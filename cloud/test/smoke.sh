#!/bin/bash
# End-to-end check of a running Reel server. Usage: test/smoke.sh <base url> <owner token> <video.mp4>
set -uo pipefail
BASE=$1; TOKEN=$2; FILE=$3
AUTH="Authorization: Bearer $TOKEN"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass+1)); else echo "FAIL $1 (got '$2', want '$3')"; fail=$((fail+1)); fi; }
SIZE=$(stat -f%z "$FILE")
# Start from an empty workspace so earlier runs don't count against the storage cap.
for old in $(curl -s -H "$AUTH" $BASE/api/videos | python3 -c 'import json,sys;print(" ".join(v["id"] for v in json.load(sys.stdin).get("videos",[])))'); do
  curl -s -o /dev/null -X DELETE -H "$AUTH" $BASE/api/videos/$old
done

check "owner API refuses a wrong token" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' $BASE/api/usage)" 401

CREATE=$(curl -s -X POST -H "$AUTH" -H 'Content-Type: application/json' $BASE/api/videos \
  -d "{\"title\":\"Point roadmap\",\"sizeBytes\":$SIZE,\"duration\":8,\"chapters\":[{\"time\":0,\"title\":\"Intro\"},{\"time\":4,\"title\":\"Délais\"}],\"cta\":{\"label\":\"Réserver un appel\",\"url\":\"https://example.com\"},\"links\":[{\"start\":1,\"end\":3,\"label\":\"Voir le tableau\",\"url\":\"https://example.com/t\"}]}")
ID=$(echo "$CREATE" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
check "video created" "$([ -n "$ID" ] && echo yes)" yes

PART=$(curl -s -X PUT -H "$AUTH" --data-binary @"$FILE" $BASE/api/videos/$ID/parts/1)
ETAG=$(echo "$PART" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("etag",""))')
check "part uploaded" "$([ -n "$ETAG" ] && echo yes)" yes
DONE='{"parts":[{"partNumber":1,"etag":"'"$ETAG"'"}]}'
check "upload completed" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "$DONE" $BASE/api/videos/$ID/complete)" 200

PAGE=$(curl -s $BASE/v/$ID)
check "share page shows the title" "$(echo "$PAGE" | grep -c 'Point roadmap' | tr -d ' ' | sed 's/^[1-9][0-9]*$/yes/')" yes
check "share page has no Reel branding" "$(echo "$PAGE" | grep -ci '>Reel<' | tr -d ' ')" 0
check "full video served" "$(curl -s -o /dev/null -w '%{http_code}:%{size_download}' $BASE/v/$ID/video)" "200:$SIZE"
check "range request served" "$(curl -s -o /dev/null -w '%{http_code}:%{size_download}' -H 'Range: bytes=0-99' $BASE/v/$ID/video)" "206:100"

check "comment posted" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' $BASE/v/$ID/comments -d '{"author":"Camille","body":"Avant ou après le changement ?","time":1.5}')" 201
check "comment listed" "$(curl -s $BASE/v/$ID/comments | python3 -c 'import json,sys;print(json.load(sys.stdin)["comments"][0]["author"])')" Camille
check "reaction posted" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' $BASE/v/$ID/reactions -d '{"kind":"heart","time":2}')" 201
VIEW=$(python3 -c 'import uuid;print(uuid.uuid4())')
curl -s -o /dev/null -X POST -H 'Content-Type: application/json' $BASE/v/$ID/views -d "{\"view\":\"$VIEW\",\"viewer\":\"Hugo\",\"percent\":40}"
curl -s -o /dev/null -X POST -H 'Content-Type: application/json' $BASE/v/$ID/views -d "{\"view\":\"$VIEW\",\"percent\":85}"
check "insights show who watched and how far" "$(curl -s -H "$AUTH" $BASE/api/videos/$ID/insights | python3 -c 'import json,sys;v=json.load(sys.stdin)["views"][0];print(v["viewer"],int(v["percent"]))')" "Hugo 85"

curl -s -o /dev/null -X PATCH -H "$AUTH" -H 'Content-Type: application/json' $BASE/api/videos/$ID -d '{"privacy":"password","password":"roadmap26"}'
check "password page shown" "$(curl -s $BASE/v/$ID | grep -c 'protégée par un mot de passe' | tr -d ' ')" 1
check "video locked without password" "$(curl -s -o /dev/null -w '%{http_code}' $BASE/v/$ID/video)" 401
check "wrong password refused" "$(curl -s -o /dev/null -w '%{redirect_url}' -X POST -d password=nope $BASE/v/$ID/unlock | grep -c wrong=1 | tr -d ' ')" 1
JAR=$(mktemp)
curl -s -o /dev/null -c $JAR -X POST -d password=roadmap26 $BASE/v/$ID/unlock
check "right password unlocks the video" "$(curl -s -o /dev/null -w '%{http_code}' -b $JAR $BASE/v/$ID/video)" 200
rm -f $JAR

check "usage reports storage" "$(curl -s -H "$AUTH" $BASE/api/usage | python3 -c 'import json,sys;print(json.load(sys.stdin)["storageBytes"]>0)')" True
check "upload over the storage cap refused" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "$AUTH" -H 'Content-Type: application/json' $BASE/api/videos -d '{"title":"Trop grosse","sizeBytes":999999999999}')" 429

check "video deleted" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "$AUTH" $BASE/api/videos/$ID)" 200
check "deleted video is gone" "$(curl -s -o /dev/null -w '%{http_code}' $BASE/v/$ID)" 404
echo "$pass passed, $fail failed"; [ $fail -eq 0 ]
