# RTSP to S3 - Home Assistant Add-on

A Home Assistant add-on that continuously captures an RTSP camera stream, splits it into fixed-duration MP4 segments, and uploads them to an Amazon S3 bucket using short-lived credentials obtained via AWS IoT Core credential provider.

> [!NOTE]
> **Tested with:** Tapo C230. Other cameras exposing a standard RTSP stream should work but have not been verified.

## Planned improvements

- **Multiple camera support** - currently the add-on supports a single camera per instance. A future version will accept a list of cameras in the configuration, each with its own RTSP URL and S3 prefix, with shared AWS credentials.
- **CloudFormation template** - the AWS setup (S3 bucket, IoT Thing, Role Alias, IAM role and policy) requires several manual steps. A CloudFormation template will be provided to provision all required resources in one go.
- **Smarter upload trigger** - currently segments are only uploaded once they are 1 minute old, which adds unnecessary delay. A better approach is to check whether ffmpeg still has the file open (via `fuser`) and upload immediately once it moves on to the next segment.

## How it works

1. `ffmpeg` connects to the camera over RTSP (TCP transport) and writes rolling MP4 segments to a local temp directory.
2. A background loop watches for completed segments (files older than 1 minute) and uploads each one to S3 under a `prefix/YYYY/MM/DD/HH/` key structure.
3. AWS credentials are obtained from the IoT Core credential provider endpoint using mutual TLS (device certificate + private key). They are refreshed automatically every ~50 minutes before expiry.
4. If `ffmpeg` exits for any reason it is restarted automatically after a configurable delay.

## Prerequisites

### Camera

- Tapo C230 (or any camera exposing an RTSP stream)
- RTSP access enabled in the camera's settings

### AWS

- An S3 bucket to store the recordings
- An AWS IoT Core **Thing** registered for your device
- An IoT **Role Alias** pointing to an IAM role with `s3:PutObject` permission on the bucket
- The device certificate, private key, and Amazon Root CA downloaded from IoT Core

### Certificates on the Home Assistant host

Place the three certificate files under a subdirectory of `/ssl/` (the default is `/ssl/camera/`):

```
/ssl/camera/
├── certificate.pem
├── private.key
└── root-ca.pem
```

The add-on mounts `/ssl` read-only, so the files just need to exist on the host before the add-on starts.

## Installation

1. In Home Assistant, go to **Settings → Add-ons → Add-on Store**.
2. Click the menu (⋮) in the top-right and choose **Repositories**.
3. Add the URL of this repository and click **Add**.
4. Find **RTSP to S3** in the store and click **Install**.

## Configuration

| Option                    | Type   | Default       | Description                                                                                        |
| ------------------------- | ------ | ------------- | -------------------------------------------------------------------------------------------------- |
| `rtsp_url`                | string | -             | Full RTSP URL including credentials, e.g. `rtsp://user:pass@192.168.1.x:554/stream2`               |
| `s3_bucket`               | string | -             | Name of the S3 bucket to upload segments to                                                        |
| `s3_prefix`               | string | `camera`      | Key prefix (folder) inside the bucket                                                              |
| `s3_region`               | string | `eu-west-2`   | AWS region of the S3 bucket                                                                        |
| `segment_duration`        | int    | `60`          | Length of each recorded segment in seconds                                                         |
| `cert_dir`                | string | `/ssl/camera` | Directory containing `certificate.pem`, `private.key`, and `root-ca.pem`                           |
| `iot_credential_endpoint` | string | -             | IoT Core credential provider hostname, e.g. `xxxxxxxxxxxx.credentials.iot.eu-west-2.amazonaws.com` |
| `iot_role_alias`          | string | -             | Name of the IoT Role Alias configured in AWS                                                       |
| `iot_thing_name`          | string | -             | Name of the IoT Thing registered in AWS                                                            |
| `restart_delay`           | int    | `10`          | Seconds to wait before restarting `ffmpeg` after an unexpected exit                                |

## S3 key structure

Uploaded segments follow this pattern:

```
{s3_prefix}/{YYYY}/{MM}/{DD}/{HH}/{YYYYMMdd_HHmmss}.mp4
```

For example:

```
camera/2026/03/06/14/20260306_143000.mp4
```

## Suggested: S3 lifecycle policy

Without a lifecycle policy, recordings accumulate indefinitely. It is strongly recommended to add a rule in the AWS console (**S3 → your bucket → Management → Lifecycle rules**) to expire objects automatically. Example policy to delete anything older than 30 days:

```json
{
  "Rules": [
    {
      "ID": "expire-camera-recordings",
      "Status": "Enabled",
      "Filter": { "Prefix": "camera/" },
      "Expiration": { "Days": 30 }
    }
  ]
}
```

Adjust `Prefix` to match your `s3_prefix` setting and `Days` to your desired retention window. You can also add a separate `NoncurrentVersionExpiration` rule if versioning is enabled on the bucket.

## Suggested: Controlling recording via Home Assistant

Rather than leaving the add-on running at all times, you can start and stop it automatically. Two common approaches are shown below - use either one or combine them.

### Option A - Manual toggle (input boolean)

Create a helper in **Settings → Devices & Services → Helpers → Toggle**, name it `Recording Enabled`, then add two automations:

```yaml
# Start the add-on when the toggle is turned on
automation:
  - alias: "Start camera recording"
    trigger:
      - platform: state
        entity_id: input_boolean.recording_enabled
        to: "on"
    action:
      - service: hassio.addon_start
        data:
          addon: rtsp_to_s3

  - alias: "Stop camera recording"
    trigger:
      - platform: state
        entity_id: input_boolean.recording_enabled
        to: "off"
    action:
      - service: hassio.addon_stop
        data:
          addon: rtsp_to_s3
```

This gives you a simple on/off switch on your dashboard to start and stop recording on demand.

### Option B - Presence detection (record only when away)

Record automatically when everyone leaves home and stop when someone arrives. This assumes you have at least one `person` entity tracked in Home Assistant:

```yaml
automation:
  - alias: "Start recording when everyone leaves"
    trigger:
      - platform: state
        entity_id: group.all_persons # or a specific person entity
        to: "not_home"
    action:
      - service: hassio.addon_start
        data:
          addon: rtsp_to_s3

  - alias: "Stop recording when someone arrives home"
    trigger:
      - platform: state
        entity_id: group.all_persons
        to: "home"
    action:
      - service: hassio.addon_stop
        data:
          addon: rtsp_to_s3
```

> [!TIP]
> You can combine both approaches - use presence detection as the primary trigger and the manual toggle as an override for times when you want to record even while home (e.g. when you go out but leave a family member behind).

## Supported architectures

- `aarch64` (Raspberry Pi 4/5 and similar)
