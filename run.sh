#!/usr/bin/with-contenv bashio
set -e

RTSP_BASE=$(bashio::config 'rtsp_url')
RTSP_USERNAME=$(bashio::config 'rtsp_username')
RTSP_PASSWORD=$(bashio::config 'rtsp_password')
RTSP_URL="${RTSP_BASE/rtsp:\/\//rtsp://$RTSP_USERNAME:$RTSP_PASSWORD@}"
S3_BUCKET=$(bashio::config 's3_bucket')
S3_PREFIX=$(bashio::config 's3_prefix')
S3_REGION=$(bashio::config 's3_region')
SEGMENT_DURATION=$(bashio::config 'segment_duration')
CERT_DIR=$(bashio::config 'cert_dir')
CRED_ENDPOINT=$(bashio::config 'iot_credential_endpoint')
ROLE_ALIAS=$(bashio::config 'iot_role_alias')
THING_NAME=$(bashio::config 'iot_thing_name')
RESTART_DELAY=$(bashio::config 'restart_delay')

SEGMENT_DIR="/tmp/rtsp-segments"

mkdir -p "$SEGMENT_DIR"

fetch_credentials() {
  curl -s \
    --cert "$CERT_DIR/certificate.pem" \
    --key "$CERT_DIR/private.key" \
    --cacert "$CERT_DIR/root-ca.pem" \
    "https://$CRED_ENDPOINT/role-aliases/$ROLE_ALIAS/credentials" \
    -H "x-amzn-iot-thingname: $THING_NAME"
}

export_credentials() {
  CREDS=$(fetch_credentials)
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['credentials']['accessKeyId'])")
  export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['credentials']['secretAccessKey'])")
  export AWS_SESSION_TOKEN=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['credentials']['sessionToken'])")
  CRED_EXPIRY=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['credentials']['expiration'])")
  echo "Credentials fetched, expire at $CRED_EXPIRY"
}

start_ffmpeg() {
  ffmpeg \
    -f rtsp \
    -rtsp_transport tcp \
    -buffer_size 1024000 \
    -use_wallclock_as_timestamps 1 \
    -i "$RTSP_URL" \
    -c:v copy \
    -c:a aac \
    -avoid_negative_ts make_zero \
    -f segment \
    -segment_time "$SEGMENT_DURATION" \
    -segment_format mp4 \
    -reset_timestamps 1 \
    -strftime 1 \
    "$SEGMENT_DIR/%Y%m%d_%H%M%S.mp4" 2>&1 &
  FFMPEG_PID=$!
  echo "Started ffmpeg with PID $FFMPEG_PID"
}

upload_segments() {
  for f in "$SEGMENT_DIR"/*.mp4; do
    [ -f "$f" ] || continue
    if [ "$(find "$f" -mmin +1 2>/dev/null)" ]; then
      FNAME=$(basename "$f" .mp4)
      YEAR=${FNAME:0:4}
      MONTH=${FNAME:4:2}
      DAY=${FNAME:6:2}
      HOUR=${FNAME:9:2}
      S3_KEY="$S3_PREFIX/$YEAR/$MONTH/$DAY/$HOUR/$FNAME.mp4"
      aws s3 cp "$f" "s3://$S3_BUCKET/$S3_KEY" \
        --region "$S3_REGION" \
        && rm "$f" \
        && echo "Uploaded $S3_KEY"
    fi
  done
}

export_credentials
LAST_REFRESH=$(date +%s)
start_ffmpeg

while true; do
  if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    echo "ffmpeg exited, restarting in ${RESTART_DELAY}s..."
    sleep "$RESTART_DELAY"
    start_ffmpeg
  fi

  NOW=$(date +%s)
  if (( NOW - LAST_REFRESH > 3000 )); then
    export_credentials
    LAST_REFRESH=$NOW
  fi

  upload_segments
  sleep 10
done
