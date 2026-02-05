#!/usr/bin/env python3
"""
Inspektor Gadget Exec Trace Collector

Captures process execution events via Inspektor Gadget's trace_exec gadget
and sends them to Azure Log Analytics for monitoring and visualization.

Environment Variables:
    LA_WORKSPACE_ID  - Azure Log Analytics Workspace ID
    LA_WORKSPACE_KEY - Azure Log Analytics Primary/Secondary Shared Key
    LA_LOG_TYPE      - Custom log type name (default: InspektorGadgetExec)
    IG_BATCH_SIZE    - Number of records per batch (default: 100)
    IG_FLUSH_INTERVAL - Seconds between flushes (default: 30)
"""
import subprocess
import json
import hashlib
import hmac
import base64
import datetime
import time
import signal
import sys
import os
from urllib.request import Request, urlopen

WORKSPACE_ID = os.environ["LA_WORKSPACE_ID"]
WORKSPACE_KEY = os.environ["LA_WORKSPACE_KEY"]
LOG_TYPE = os.environ.get("LA_LOG_TYPE", "InspektorGadgetExec")
BATCH_SIZE = int(os.environ.get("IG_BATCH_SIZE", "100"))
FLUSH_INTERVAL = int(os.environ.get("IG_FLUSH_INTERVAL", "30"))

ig_process = None


def build_signature(date, content_length):
    x_headers = "x-ms-date:" + date
    string_to_hash = "POST\n{}\napplication/json\n{}\n/api/logs".format(
        content_length, x_headers
    )
    decoded_key = base64.b64decode(WORKSPACE_KEY)
    encoded_hash = base64.b64encode(
        hmac.new(
            decoded_key, string_to_hash.encode("utf-8"), digestmod=hashlib.sha256
        ).digest()
    ).decode("utf-8")
    return "SharedKey {}:{}".format(WORKSPACE_ID, encoded_hash)


def post_data(body):
    rfc1123date = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S GMT"
    )
    content_length = len(body)
    signature = build_signature(rfc1123date, content_length)
    uri = "https://{}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01".format(
        WORKSPACE_ID
    )
    req = Request(uri, data=body.encode("utf-8"), method="POST")
    req.add_header("content-type", "application/json")
    req.add_header("Authorization", signature)
    req.add_header("Log-Type", LOG_TYPE)
    req.add_header("x-ms-date", rfc1123date)
    try:
        resp = urlopen(req)
        return resp.status
    except Exception as e:
        print("Error posting to LA: {}".format(e), file=sys.stderr, flush=True)
        return 0


def shutdown_handler(signum, frame):
    print("Received signal {}, shutting down...".format(signum), flush=True)
    if ig_process:
        ig_process.terminate()
    sys.exit(0)


def collect_and_send():
    global ig_process

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    print(
        "Starting Inspektor Gadget exec trace collector "
        "(batch_size={}, flush_interval={}s, log_type={})".format(
            BATCH_SIZE, FLUSH_INTERVAL, LOG_TYPE
        ),
        flush=True,
    )

    ig_process = subprocess.Popen(
        ["ig", "run", "trace_exec", "--host", "-o", "json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    batch = []
    last_send = time.time()

    for line in ig_process.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
            proc_info = event.get("proc", {})
            record = {
                "Timestamp": event.get(
                    "timestamp",
                    datetime.datetime.now(datetime.timezone.utc).isoformat(),
                ),
                "Comm": proc_info.get("comm", ""),
                "Pid": proc_info.get("pid", 0),
                "Tid": proc_info.get("tid", 0),
                "ParentComm": proc_info.get("parent", {}).get("comm", ""),
                "ParentPid": proc_info.get("parent", {}).get("pid", 0),
                "Args": event.get("args", ""),
                "Uid": proc_info.get("creds", {}).get("uid", 0),
                "User": proc_info.get("creds", {}).get("user", ""),
                "ExecCount": 1,
            }
            batch.append(record)
        except json.JSONDecodeError:
            continue

        now = time.time()
        if len(batch) >= BATCH_SIZE or (now - last_send) >= FLUSH_INTERVAL:
            if batch:
                body = json.dumps(batch)
                status = post_data(body)
                print(
                    "Sent {} records, status: {}".format(len(batch), status), flush=True
                )
                batch = []
                last_send = now


if __name__ == "__main__":
    collect_and_send()
