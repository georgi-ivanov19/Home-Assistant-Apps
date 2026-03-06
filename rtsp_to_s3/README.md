# RTSP to S3 - Home Assistant Add-on

A Home Assistant add-on that continuously captures an RTSP camera stream, splits it into fixed-duration MP4 segments, and uploads them to an Amazon S3 bucket using short-lived credentials obtained via AWS IoT Core credential provider.

> [!NOTE]
> **Tested with:** Tapo C230. Other cameras exposing a standard RTSP stream should work but have not been verified.

## Planned improvements

- **Multiple camera support** - currently the add-on supports a single camera per instance. A future version will accept a list of cameras in the configuration, each with its own RTSP URL and S3 prefix, with shared AWS credentials.

## How it works

1. `ffmpeg` connects to the camera over RTSP (TCP transport) and writes rolling MP4 segments to a local temp directory.
2. A background loop checks each segment with `fuser` to see whether `ffmpeg` still has it open. As soon as the file is released (i.e. `ffmpeg` has moved on to the next segment), it is uploaded to S3 under a `prefix/YYYY/MM/DD/HH/` key structure and deleted locally.
3. If buffered segments exceed the configured storage limit (`max_segment_storage_mb`), the oldest unuploaded files are purged to prevent the disk from filling up.
4. AWS credentials are obtained from the IoT Core credential provider endpoint using mutual TLS (device certificate + private key). They are refreshed automatically every ~50 minutes before expiry.
5. If `ffmpeg` exits for any reason it is restarted automatically after a configurable delay.

## Prerequisites

### Camera

- Tapo C230 (or any camera exposing an RTSP stream)
- RTSP access enabled in the camera's settings

### AWS

- An S3 bucket to store the recordings
- An AWS IoT Core **Thing** registered for your device
- An IoT **Role Alias** pointing to an IAM role with `s3:PutObject` permission on the bucket
- The device certificate, private key, and Amazon Root CA downloaded from IoT Core

All of these (except the certificate) can be provisioned in one go using the [CloudFormation template](#aws-setup-with-cloudformation) included in this repository.

### Certificates on the Home Assistant host

Place the three certificate files under a subdirectory of `/ssl/` (the default is `/ssl/camera/`):

```
/ssl/camera/
├── certificate.pem
├── private.key
└── root-ca.pem
```

The add-on mounts `/ssl` read-only, so the files just need to exist on the host before the add-on starts.

## AWS setup with CloudFormation

The included CloudFormation template (`cloudformation.yaml`) creates all the required AWS resources except the IoT device certificate, which must be created separately so that the private key can be downloaded.

### 1. Deploy the stack

```bash
aws cloudformation deploy \
  --template-file cloudformation.yaml \
  --stack-name rtsp-to-s3 \
  --parameter-overrides \
    BucketName=<bucket-name> \
    ThingName=<thing-name> \
    EnableLifecycleExpiration=<true|false> \
    LifecycleExpirationDays=<days> \
    S3Prefix=<prefix> \
  --capabilities CAPABILITY_NAMED_IAM \
  --region <region>
```

| Parameter | Required | Default | Description |
| --------- | -------- | ------- | ----------- |
| `BucketName` | yes | - | Name of the S3 bucket to create |
| `ThingName` | yes | - | Name for the IoT Thing |
| `EnableLifecycleExpiration` | yes | - | `true` or `false` - enable automatic object expiration |
| `LifecycleExpirationDays` | no | `30` | Days before objects expire (ignored when expiration is disabled) |
| `S3Prefix` | no | `camera` | Key prefix for the lifecycle rule filter (should match the add-on `s3_prefix` option) |

The stack creates:

- **S3 bucket** with public access blocked and an optional lifecycle expiration rule
- **IoT Thing**
- **IAM role** trusted by `credentials.iot.amazonaws.com` with an inline policy granting `s3:PutObject` on the bucket
- **IoT Role Alias** pointing to the IAM role (1-hour credential duration)
- **IoT Policy** allowing `iot:AssumeRoleWithCertificate` on the role alias

> [!NOTE]
> The S3 bucket has a `Retain` deletion policy - deleting the stack will **not** delete the bucket or its contents.

### 2. View stack outputs

After the deploy completes, retrieve the output values you will need for the remaining steps and for the add-on configuration:

```bash
aws cloudformation describe-stacks \
  --stack-name rtsp-to-s3 \
  --query 'Stacks[0].Outputs' \
  --region eu-west-2
```

### 3. Create the device certificate

You can create the certificate using the **AWS CLI** or the **AWS Console**.

#### Option A - AWS CLI

```bash
aws iot create-keys-and-certificate \
  --set-as-active \
  --certificate-pem-outfile certificate.pem \
  --private-key-outfile private.key \
  --region <region>
```

This writes `certificate.pem` and `private.key` to the current directory and prints a JSON response. Note the `certificateArn` from the output - you need it in the next step.

Download the Amazon Root CA:

```bash
curl -o root-ca.pem https://www.amazontrust.com/repository/AmazonRootCA1.pem
```

#### Option B - AWS Console

1. Open the **AWS IoT Console** → **Security** → **Certificates** → **Add certificate** → **Create certificate**.
2. Choose **Auto-generate new certificate** and click **Create**.
3. On the confirmation page, download all three files:
   - **Device certificate** (`*-certificate.pem.crt`) - save as `certificate.pem`
   - **Private key** (`*-private.pem.key`) - save as `private.key`
   - **Amazon Root CA 1** - save as `root-ca.pem`

> [!WARNING]
> The private key can only be downloaded at the time of creation. If you miss it you will need to create a new certificate.

4. The certificate is created in an **Inactive** state. Select it from the list and click **Actions** → **Activate**.

### 4. Attach the certificate to the thing and policy

#### AWS CLI

Replace `<certificate-arn>` with the ARN from step 3, and `<thing-name>` / `<policy-name>` with the values from the stack outputs:

```bash
aws iot attach-thing-principal \
  --thing-name <thing-name> \
  --principal <certificate-arn> \
  --region <region>

aws iot attach-policy \
  --policy-name <policy-name> \
  --target <certificate-arn> \
  --region <region>
```

#### AWS Console

1. Open the **AWS IoT Console** → **Security** → **Certificates**.
2. Select the certificate you created in step 3.
3. Click **Actions** → **Attach policy**, select `<policy-name>` from the stack outputs, and confirm.
4. Click **Actions** → **Attach thing**, select `<thing-name>` from the stack outputs, and confirm.

### 5. Get the IoT credential endpoint

```bash
aws iot describe-endpoint \
  --endpoint-type iot:CredentialProvider \
  --region <region>
```

Use the `endpointAddress` value for the add-on's `iot_credential_endpoint` option.

Alternatively, in the **AWS IoT Console**, go to **Settings** - the **Credential provider endpoint** is listed under **Device data endpoint**.

### 6. Copy certificates to the Home Assistant host

Copy the three certificate files to `/ssl/camera/` (or whichever path you configure as `cert_dir`) on your Home Assistant host:

```
/ssl/camera/
├── certificate.pem
├── private.key
└── root-ca.pem
```

For example, using `scp`:

```bash
scp certificate.pem private.key root-ca.pem <user>@<ha-host>:/ssl/camera/
```

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
| `segment_duration`        | int    | `300`         | Length of each recorded segment in seconds                                                         |
| `cert_dir`                | string | `/ssl/camera` | Directory containing `certificate.pem`, `private.key`, and `root-ca.pem`                           |
| `iot_credential_endpoint` | string | -             | IoT Core credential provider hostname, e.g. `xxxxxxxxxxxx.credentials.iot.eu-west-2.amazonaws.com` |
| `iot_role_alias`          | string | -             | Name of the IoT Role Alias configured in AWS                                                       |
| `iot_thing_name`          | string | -             | Name of the IoT Thing registered in AWS                                                            |
| `restart_delay`           | int    | `10`          | Seconds to wait before restarting `ffmpeg` after an unexpected exit                                |
| `max_segment_storage_mb`  | int    | `2048`        | Maximum MB of disk for buffered segments - oldest unuploaded files are purged when exceeded         |

## S3 key structure

Uploaded segments follow this pattern:

```
{s3_prefix}/{YYYY}/{MM}/{DD}/{HH}/{YYYYMMdd_HHmmss}.mp4
```

For example:

```
camera/2026/03/06/14/20260306_143000.mp4
```

## S3 lifecycle policy

Without a lifecycle policy, recordings accumulate indefinitely. If you deployed with `EnableLifecycleExpiration=true`, the CloudFormation template has already configured this for you. Otherwise you can add a rule manually in the AWS console (**S3 → your bucket → Management → Lifecycle rules**) or via the CLI:

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

Adjust `Prefix` to match your `s3_prefix` setting and `Days` to your desired retention window.

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
